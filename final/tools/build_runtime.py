"""Windows job-object timeout and suspend protection for one build phase."""
import ctypes
from ctypes import wintypes as W
from datetime import datetime
import hashlib
import json
import re
import subprocess
import time

KERNEL = ctypes.WinDLL("kernel32", use_last_error=True)


class BasicLimits(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_longlong),
        ("PerJobUserTimeLimit", ctypes.c_longlong),
        ("LimitFlags", W.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
        ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", W.DWORD),
        ("Affinity", ctypes.c_size_t), ("PriorityClass", W.DWORD),
        ("SchedulingClass", W.DWORD)]


class IoCounters(ctypes.Structure):
    _fields_ = [(name, ctypes.c_ulonglong) for name in (
        "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
        "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]


class ExtendedLimits(ctypes.Structure):
    _fields_ = [
        ("BasicLimitInformation", BasicLimits), ("IoInfo", IoCounters),
        ("ProcessMemoryLimit", ctypes.c_size_t), ("JobMemoryLimit", ctypes.c_size_t),
        ("PeakProcessMemoryUsed", ctypes.c_size_t), ("PeakJobMemoryUsed", ctypes.c_size_t)]


KERNEL.CreateJobObjectW.argtypes = [ctypes.c_void_p, W.LPCWSTR]
KERNEL.CreateJobObjectW.restype = W.HANDLE
KERNEL.SetInformationJobObject.argtypes = [W.HANDLE, ctypes.c_int, ctypes.c_void_p, W.DWORD]
KERNEL.AssignProcessToJobObject.argtypes = [W.HANDLE, W.HANDLE]
KERNEL.TerminateJobObject.argtypes = [W.HANDLE, W.UINT]
KERNEL.CloseHandle.argtypes = [W.HANDLE]
KERNEL.SetThreadExecutionState.argtypes = [W.DWORD]
KERNEL.SetThreadExecutionState.restype = W.DWORD
NTDLL = ctypes.WinDLL("ntdll")
NTDLL.NtResumeProcess.argtypes = [W.HANDLE]
POWER = ctypes.WinDLL("powrprof", use_last_error=True)
POWER_CALLBACK = ctypes.WINFUNCTYPE(W.ULONG, ctypes.c_void_p, W.ULONG, ctypes.c_void_p)


class PowerSubscription(ctypes.Structure):
    _fields_ = [("Callback", POWER_CALLBACK), ("Context", ctypes.c_void_p)]


POWER.PowerRegisterSuspendResumeNotification.argtypes = [
    W.DWORD, ctypes.c_void_p, ctypes.POINTER(W.HANDLE)]
POWER.PowerRegisterSuspendResumeNotification.restype = W.DWORD
POWER.PowerUnregisterSuspendResumeNotification.argtypes = [W.HANDLE]
POWER.PowerUnregisterSuspendResumeNotification.restype = W.DWORD


class SuspendGuard:
    """Fail closed on a sleep notification, rather than carry a build over sleep."""

    def __init__(self, job):
        self.job = job
        self.events = []
        self.interrupted = False
        self.callback = POWER_CALLBACK(self.notify)
        self.subscription = PowerSubscription(self.callback, None)
        self.handle = W.HANDLE()
        code = POWER.PowerRegisterSuspendResumeNotification(
            2, ctypes.byref(self.subscription), ctypes.byref(self.handle))
        if code:
            raise OSError(code, "Cannot register build suspend guard")

    def notify(self, context, event, setting):
        if event == 4:  # PBT_APMSUSPEND: terminate before allowing a long sleep.
            self.interrupted = True
            killed = bool(KERNEL.TerminateJobObject(self.job, 125))
            self.events.append({"event": "SUSPEND", "time": now(), "job_terminated": killed})
        return 0

    def close(self):
        if self.handle:
            code = POWER.PowerUnregisterSuspendResumeNotification(self.handle)
            if code:
                raise OSError(code, "Cannot unregister build suspend guard")
            self.handle = W.HANDLE()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def now():
    return datetime.now().astimezone().isoformat()


def stage(stage_name, limit, command=None, reject_pattern=None):
    job = KERNEL.CreateJobObjectW(None, None)
    if not job:
        raise ctypes.WinError(ctypes.get_last_error())
    limits = ExtendedLimits()
    limits.BasicLimitInformation.LimitFlags = 0x2000  # Kill all descendants on close.
    process = None
    power_guard = None
    started = time.monotonic()
    wall_deadline = time.time() + limit
    result = {"started": now(), "limit_seconds": limit, "status": "RUNNING"}
    (OUT / f"{stage_name}_live.json").write_text(json.dumps(result, indent=2))
    try:
        if not KERNEL.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            raise ctypes.WinError(ctypes.get_last_error())
        power_guard = SuspendGuard(job)
        with (OUT / f"{stage_name}.log").open("w") as log:
            # Assign the suspended root before it can create any child tools.
            process = subprocess.Popen(
                command or [GW, str(PROJECT / "build_stage.tcl"), stage_name],
                cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT,
                creationflags=subprocess.CREATE_NO_WINDOW | 0x4)
            if not KERNEL.AssignProcessToJobObject(job, W.HANDLE(process._handle)):
                raise ctypes.WinError(ctypes.get_last_error())
            if power_guard.interrupted:
                raise RuntimeError("Sleep interrupted build startup")
            if NTDLL.NtResumeProcess(W.HANDLE(process._handle)) != 0:
                raise RuntimeError("Cannot resume bounded build process")
            try:
                # Recheck wall time after resume; a single Windows wait may not
                # count time spent suspended toward its timeout.
                while True:
                    if reject_pattern and re.search(
                            reject_pattern, (OUT / f"{stage_name}.log").read_text(
                                errors="replace"), re.I):
                        KERNEL.TerminateJobObject(job, 126)
                        process.wait(30)
                        result.update(status="REJECTED_UNEXPECTED_SYNTHESIS",
                                      exit_code=126)
                        break
                    remaining = min(limit-(time.monotonic()-started),
                                    wall_deadline-time.time())
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired(process.args, limit)
                    try:
                        code = process.wait(min(1.0, remaining))
                        break
                    except subprocess.TimeoutExpired:
                        continue
                if result["status"] == "RUNNING":
                    result.update(exit_code=code, status="TOOL_FINISHED" if code == 0 else "FAILED")
            except subprocess.TimeoutExpired:
                KERNEL.TerminateJobObject(job, 124)
                process.wait(30)
                result["status"] = "TIMEOUT"
    finally:
        if power_guard is not None:
            power_guard.close()
            result["power_events"] = power_guard.events
            if power_guard.interrupted:
                result["status"] = "INTERRUPTED_SUSPEND"
        KERNEL.CloseHandle(job)
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(30)
        result["seconds"] = round(time.monotonic()-started, 3)
        result["finished"] = now()
    text = (OUT / f"{stage_name}.log").read_text(errors="replace")
    result["completion_guard"] = bool(re.search(
        rf"^BUILD STAGE COMPLETE {stage_name}\s*$", text, flags=re.MULTILINE))
    result["tool_errors"] = bool(re.search(r"\bERROR\s*(?:\(|:)|TCL_ERROR", text, re.I))
    if reject_pattern and re.search(reject_pattern, text, re.I):
        result["status"] = "REJECTED_UNEXPECTED_SYNTHESIS"
    if result["status"] == "TOOL_FINISHED":
        result["status"] = "PASS" if result["completion_guard"] and not result["tool_errors"] else "FAILED"
    (OUT / f"{stage_name}_live.json").write_text(json.dumps(result, indent=2))
    return result


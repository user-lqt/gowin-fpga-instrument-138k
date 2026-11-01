"""Logic 2 local automation. Detection never starts a capture."""

from pathlib import Path
import json
import socket
import time


def connect():
    try:
        from saleae import automation
    except ImportError as error:
        raise RuntimeError("缺少 logic2-automation，请使用安装了该包的 Python 启动软件。") from error
    try:
        # Probe the local listener first to avoid an unbounded gRPC connection.
        with socket.create_connection(("127.0.0.1", 10430), timeout=2):
            pass
        return automation.Manager.connect(port=10430, connect_timeout_seconds=5)
    except Exception as error:
        raise RuntimeError("无法连接 Logic 2 自动化接口。请运行 Logic 2，在 Edit → Settings "
                           "勾选 Enable Automation Server（127.0.0.1:10430）。") from error


def device(manager):
    devices = manager.get_devices(include_simulation_devices=False)
    devices = [d for d in devices if not d.is_simulation]
    if len(devices) != 1:
        raise RuntimeError(f"需恰好一台真实逻辑分析仪，目前检测到 {len(devices)} 台；不使用模拟设备。")
    return devices[0]


def detect():
    with connect() as manager:
        found = device(manager)
        return f"Logic 2 已连接：{found.device_type.name} / {found.device_id}；未启动采集。"


class ScopeControl:
    def __init__(self, host):
        self.host = host

    def __enter__(self):
        self.sock = socket.create_connection((self.host, 5555), timeout=5)
        self.sock.settimeout(5)
        self.stream = self.sock.makefile("rb")
        return self

    def send(self, cmd):
        self.sock.sendall((cmd + "\n").encode("ascii"))

    def query(self, cmd):
        self.send(cmd)
        return self.stream.readline().decode("ascii").strip()

    def __exit__(self, *_args):
        self.stream.close()
        self.sock.close()


def wait_single_ready(scope, record, save, notify):
    """Observe one SINGLE only; never rearm a prematurely triggered capture."""
    consecutive = 0
    saw_trigger = False
    saw_waiting = False
    for _ in range(21):
        raw_state = scope.query(":TRIG:STAT?")
        record["scope_start_states"].append(raw_state)
        state = raw_state.upper().replace("'", "").strip()
        save()
        if state in ("WAIT", "RUN"):
            consecutive += 1
            saw_waiting = True
            if consecutive == 2:
                record["startup_ready_confirmations"] = consecutive
                record["startup_td_observed"] = saw_trigger
                save()
                return
        elif state == "TD":
            consecutive = 0
            if not saw_trigger:
                notify("JOINT_ARMING 启动状态暂为 TD，继续观察同一次 SINGLE；"
                       "先不要按键，不会自动重新触发。")
            saw_trigger = True
        elif state == "STOP":
            consecutive = 0
            if saw_trigger or saw_waiting:
                raise RuntimeError(
                    "提示按键前，示波器在 TD/等待状态后已返回 STOP；"
                    "本次单次采集在按键提示前已结束，未确认目标按压。"
                    "软件未重复发送 SINGLE。请保持琴键释放；"
                    "这是启动/提前触发问题，不是按键延迟超标，也不能仅据此认定接线错误。"
                    "具体状态顺序见 capture.json。")
        else:
            raise RuntimeError(
                f"提示按键前示波器返回未支持的状态 {raw_state!r}，"
                "未确认单次采集已就绪；本次不提示按键、不自动重新采集。")
        time.sleep(.05)
    if saw_trigger:
        raise RuntimeError(
            "发送 SINGLE 后约1秒内出现 TD，但未连续确认等待/运行状态；"
            "可能已提前触发，或启动状态尚未稳定，现有状态不足以区分。"
            "本次未提示按键，未重复发送 SINGLE；不能仅凭此提示断定触发设置或接线错误。"
            "具体状态顺序见 capture.json。")
    if saw_waiting:
        raise RuntimeError(
            "发送 SINGLE 后曾观察到 WAIT/RUN，但约1秒内未连续确认两次就绪状态；"
            "本次未提示按键，软件没有自动重新采集。具体状态顺序见 capture.json。")
    raise RuntimeError(
        "发送 SINGLE 后约 1 秒内始终读到 STOP，或未连续确认等待状态；"
        "未确认进入等待状态。可能未成功启动或在提示按键前已触发；"
        "请保持琴键释放。本次未提示按键，软件没有自动重新采集。"
        "具体状态顺序见 capture.json。")


def acquire(host, output, rate=24_000_000, timeout=15., notify=print,
            manager_factory=connect, scope_factory=ScopeControl):
    """Only call following an explicit joint-capture button confirmation."""
    from saleae import automation
    output = Path(output)
    if rate not in (12_000_000, 24_000_000) or not 3 <= timeout <= 30:
        raise ValueError("联合采集只支持 12/24 MHz，等待时间为 3～30 秒。")
    with manager_factory() as manager:
        found = device(manager)
        with scope_factory(host) as scope:
            if "DS2202A,DS2D192700914" not in scope.query("*IDN?"):
                raise RuntimeError("示波器型号或序列号不符。")
            if scope.query(":TRIG:STAT?") != "STOP":
                raise RuntimeError("启动前示波器必须 STOP；不接管用户正在运行的采集。")
            from scope_preflight import JOINT_TRIGGER_COMMANDS, joint_trigger_errors
            trigger_errors = joint_trigger_errors({command: scope.query(command)
                                                   for command in JOINT_TRIGGER_COMMANDS})
            if trigger_errors:
                raise RuntimeError("\n".join(trigger_errors))
            output.mkdir(parents=True, exist_ok=False)
            record = dict(status="incomplete", device_id=found.device_id,
                          device_type=found.device_type.name, is_simulation=False,
                          digital_sample_rate_hz=rate, channels={"A": 0, "B": 1, "column": 2},
                          timeout_s=timeout, scope_commands=[":SING"],
                          host_time_is_not_hardware_sync=True,
                          stage="准备逻辑采集", scope_start_states=[])
            def save():
                (output / "capture.json").write_text(
                    json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
            save()
            capture = None
            stopped = False
            armed = False
            scope_complete = False
            try:
                capture = manager.start_capture(
                    device_id=found.device_id,
                    device_configuration=automation.LogicDeviceConfiguration(
                        enabled_digital_channels=[0, 1, 2], digital_sample_rate=rate),
                    capture_configuration=automation.CaptureConfiguration(
                        buffer_size_megabytes=256,
                        capture_mode=automation.ManualCaptureMode()))
                time.sleep(.25)
                armed = True
                record["stage"] = "等待示波器进入单次采集"
                save()
                scope.send(":SING")
                wait_single_ready(scope, record, save, notify)
                record["stage"] = "等待目标按键"
                save()
                notify("JOINT_READY 两台仪器已开始记录，现在只按一次目标键，保持到保存开始。")
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    state = scope.query(":TRIG:STAT?")
                    if state == "STOP":
                        scope_complete = True
                        break
                    if state.upper().replace("'", "") not in ("WAIT", "RUN", "TD"):
                        raise RuntimeError(
                            f"提示按键后示波器返回异常状态 {state!r}，"
                            "单次采集流程未完成；本次不作为有效测量。")
                    time.sleep(.1)
                if not scope_complete:
                    raise TimeoutError("等待按键触发超时；本次不生成达标结论。")
                notify("JOINT_CAPTURED 示波器已触发并停止，正在保存；可以松开琴键，请勿再次按键。")
                time.sleep(.1)
                # The API requires exactly one stop() before export.
                stopped = True
                capture.stop()
                record["stage"] = "导出逻辑数据"
                save()
                notify("JOINT_EXPORT 正在保存逻辑分析仪原始会话和数字数据。")
                capture.save_capture(str((output / "capture.sal").resolve()))
                capture.export_raw_data_csv(str(output.resolve()), digital_channels=[0, 1, 2])
                if not (output / "digital.csv").is_file():
                    raise RuntimeError("Logic 2 未导出 digital.csv。")
                record["status"] = "complete"
                record["stage"] = "逻辑记录已保存"
                record["scope_stopped_after_single"] = True
                save()
                return output / "digital.csv"
            except Exception as error:
                record["error"] = str(error)
                save()
                raise
            finally:
                if armed and not scope_complete:
                    try:
                        scope.send(":STOP")
                    except Exception as cleanup_error:
                        record["scope_cleanup_error"] = str(cleanup_error)
                        save()
                if capture is not None:
                    if not stopped:
                        try:
                            capture.stop()
                        except Exception:
                            pass
                    if record["status"] != "complete":
                        try:
                            if not (output / "capture.sal").exists():
                                capture.save_capture(str((output / "capture.sal").resolve()))
                        except Exception as cleanup_error:
                            record["logic_recovery_error"] = str(cleanup_error)
                            save()
                    # Only close captures whose data have already been saved.
                    if record["status"] == "complete":
                        capture.close()

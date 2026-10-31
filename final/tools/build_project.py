"""Supervised Windows rebuild. Never overwrite the frozen bitstream directory."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
import sys
import xml.etree.ElementTree as ET

from verify_package import ROOT, sha, verify


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gw-sh", required=True, type=Path)
    parser.add_argument("--voices", type=int, choices=(64,), default=64)
    parser.add_argument("--syn-seconds", type=int, default=1200)
    parser.add_argument("--pnr-seconds", type=int, default=1800)
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("The supervised process-tree runner requires Windows")
    if not (1 <= args.syn_seconds <= 1200 and 1 <= args.pnr_seconds <= 1800):
        parser.error("Maximum SYN=1200 seconds; PNR=1800 seconds")
    tool = args.gw_sh.resolve(strict=True)
    verify()
    import build_runtime as runtime
    name = f"integrated_instrument_{args.voices}"
    project = ROOT / "project" / name
    out = ROOT / "builds" / datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    out.mkdir(parents=True)
    runtime.PROJECT, runtime.OUT, runtime.GW = project, out, str(tool)
    inputs = {p.relative_to(project).as_posix(): sha(p) for p in project.rglob("*")
              if p.is_file() and "impl" not in p.relative_to(project).parts}
    report = {"status": "RUNNING", "stages": {}, "inputs": inputs}

    def save():
        (out / "result.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    def unchanged():
        if not all(sha(project / p) == h for p, h in inputs.items()):
            raise RuntimeError("Build inputs changed while tool was running")

    save()
    awake = runtime.KERNEL.SetThreadExecutionState(0x80000001)
    try:
        if not awake:
            raise RuntimeError("Cannot inhibit idle sleep")
        for directory in ("gwsynthesis", "pnr"):
            previous = project / "impl" / directory
            if previous.exists():
                raise RuntimeError("Existing build outputs found. Archive/remove impl/"
                                   + directory + " explicitly before rebuilding")
        for phase, maximum in (("syn", args.syn_seconds), ("pnr", args.pnr_seconds)):
            unchanged()
            report["stages"][phase] = runtime.stage(phase, maximum)
            save()
            unchanged()
            if report["stages"][phase]["status"] != "PASS":
                raise RuntimeError(f"{phase} did not pass")
            start = datetime.fromisoformat(report["stages"][phase]["started"]).timestamp()
            if phase == "syn":
                netlist = project / f"impl/gwsynthesis/{name}.vg"
                resources = project / f"impl/gwsynthesis/{name}_syn_rsc.xml"
                if min(netlist.stat().st_mtime, resources.stat().st_mtime) < start:
                    raise RuntimeError("Synthesis output is stale")
                attributes = ET.parse(resources).getroot().attrib
                for key, capacity in (("T_Register", 139095), ("T_Lut", 138240),
                                      ("T_Alu", 138240), ("T_Bsram", 340)):
                    if int(attributes[key].split("(")[0]) > capacity:
                        raise RuntimeError("Resource overflow: " + key)
                report["netlist_sha256"] = sha(netlist)
                shutil.copy2(resources, out / resources.name)
            else:
                if sha(netlist) != report["netlist_sha256"]:
                    raise RuntimeError("Netlist changed during PNR")
                image = project / f"impl/pnr/{name}.fs"
                if image.stat().st_mtime < start:
                    raise RuntimeError("Bitstream is stale")
                report["new_bitstream_sha256"] = sha(image)
                shutil.copy2(image, out / image.name)
        report["status"] = "PASS"
    except BaseException as exc:
        report.update(status="STOPPED", reason=str(exc))
        raise
    finally:
        runtime.KERNEL.SetThreadExecutionState(0x80000000)
        report["inputs_unchanged"] = all(sha(project / p) == h for p, h in inputs.items())
        save()
        print("Build report:", out)


if __name__ == "__main__":
    main()

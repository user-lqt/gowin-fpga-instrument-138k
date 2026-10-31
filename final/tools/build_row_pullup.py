"""Bounded build of this copy; preserve the frozen production bitstream."""

import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET

import build_runtime as runtime


class PinTable(HTMLParser):
    def __init__(self):
        super().__init__()
        self.rows, self.row, self.cell = [], None, None

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self.row = []
        elif tag in ("td", "th") and self.row is not None:
            self.cell = []

    def handle_data(self, data):
        if self.cell is not None:
            self.cell.append(data)

    def handle_endtag(self, tag):
        if tag in ("td", "th") and self.cell is not None:
            self.row.append("".join(self.cell).strip())
            self.cell = None
        elif tag == "tr" and self.row is not None:
            self.rows.append(self.row)
            self.row = None


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--gw-sh", type=Path, required=True)
    parser.add_argument("--attempt", type=int, default=1)
    parser.add_argument("--syn-seconds", type=int, default=1200)
    args = parser.parse_args()
    root = args.root.absolute()
    project = root / "project/integrated_instrument_64"
    if args.attempt < 1 or not 1 <= args.syn_seconds <= 2400:
        parser.error("Positive attempt required; synthesis limit must be 1..2400 seconds")
    output = root / f"builds/row_pullup_{args.attempt:03}"
    output.mkdir(parents=True, exist_ok=False)
    report = {"status": "PREFLIGHT", "stages": {}, "root": str(root),
              "scope": "Eight row pull modes NONE -> UP only; no RTL or pin changes"}

    def save():
        (output / "result.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    frozen = root / "bitstream/integrated_instrument_64.fs"
    frozen_hash = sha(frozen)
    manifest = json.loads((root / "package_manifest.json").read_text(encoding="utf-8"))
    cst_relative = "project/integrated_instrument_64/source/constraint/instrument_24_rgb_mega138k.cst"
    source_cst = root / cst_relative
    before = (root / "reports/row_pullup_source_before.cst").read_bytes()
    after = source_cst.read_bytes()
    old_lines, new_lines = before.splitlines(), after.splitlines()
    diff = [(a, b) for a, b in zip(old_lines, new_lines) if a != b]
    if len(old_lines) != len(new_lines) or len(diff) != 8:
        raise RuntimeError("Expected exactly eight changed CST lines")
    for i, (old, new) in enumerate(diff):
        if (not old.startswith(f'IO_PORT "row_out[{i}]"'.encode())
                or old.replace(b"PULL_MODE=NONE", b"PULL_MODE=UP") != new):
            raise RuntimeError("Unexpected CST change")
    if hashlib.sha256(before).hexdigest() != manifest["files"][cst_relative]:
        raise RuntimeError("Baseline CST does not match frozen source manifest")
    for relative, expected in manifest["files"].items():
        if relative.startswith("project/integrated_instrument_64/") and relative != cst_relative:
            if sha(root / relative) != expected:
                raise RuntimeError("Unrelated 64-voice input differs: " + relative)
    report["preexisting_manifest_differences"] = [
        relative for relative, expected in manifest["files"].items()
        if not (root / relative).is_file() or sha(root / relative) != expected]
    for entry in ET.parse(project / "integrated_instrument_64.gprj").iter("File"):
        source = project / entry.attrib["path"]
        if not source.is_file() or not source.resolve().is_relative_to(project.resolve()):
            raise RuntimeError("Missing or escaping project dependency: " + str(source))
    for name in ("gwsynthesis", "pnr"):
        if (project / "impl" / name).exists():
            raise RuntimeError("Refusing existing build output: " + name)
    inputs = {p.relative_to(project).as_posix(): sha(p)
              for p in project.rglob("*")
              if p.is_file() and "impl" not in p.relative_to(project).parts}
    report.update(inputs=inputs, frozen_bitstream_sha256=frozen_hash,
                  source_cst_before_sha256=hashlib.sha256(before).hexdigest(),
                  source_cst_after_sha256=hashlib.sha256(after).hexdigest(), status="RUNNING")
    runtime.PROJECT, runtime.OUT, runtime.GW = project, output, str(args.gw_sh.absolute())

    def unchanged():
        if any(sha(project / p) != digest for p, digest in inputs.items()):
            raise RuntimeError("Project input changed while building")
        if sha(frozen) != frozen_hash:
            raise RuntimeError("Frozen bitstream changed")

    awake = runtime.KERNEL.SetThreadExecutionState(0x80000001)
    save()
    try:
        if not awake:
            raise RuntimeError("Cannot inhibit idle sleep")
        for phase, limit in (("syn", args.syn_seconds), ("pnr", 1800)):
            unchanged()
            report["stages"][phase] = runtime.stage(phase, limit)
            save()
            unchanged()
            if report["stages"][phase]["status"] != "PASS":
                raise RuntimeError(phase + " failed; inspect stage logs")
            if phase == "syn":
                netlist = project / "impl/gwsynthesis/integrated_instrument_64.vg"
                if not netlist.is_file():
                    raise RuntimeError("Synthesis did not produce netlist")
                report["netlist_sha256"] = sha(netlist)
            elif sha(netlist) != report["netlist_sha256"]:
                raise RuntimeError("PNR changed synthesis netlist")
        physical = project / "impl/pnr"
        io_report = physical / "integrated_instrument_64.pin.html"
        if not io_report.is_file():
            raise RuntimeError("Physical IO report missing; verify pulls before delivery")
        table = PinTable()
        table.feed(io_report.read_text(errors="replace"))
        header = next(row for row in table.rows if row and row[0] == "Port Name"
                      and "Pull Mode" in row)
        pull_rows = []
        for index, ball in enumerate(("E14", "E13", "C15", "C14", "B13", "C13", "A14", "A13")):
            matches = [row for row in table.rows if row and row[0] == f"row_out[{index}]"]
            if len(matches) != 1 or len(matches[0]) != len(header):
                raise RuntimeError(f"Physical row {index} report missing/ambiguous")
            row = dict(zip(header, matches[0]))
            if (row["Pull Mode"] != "UP" or row["Loc./Bank"].split("/")[0] != ball
                    or row["IO Type"] != "LVCMOS33"):
                raise RuntimeError(f"Physical row {index} UP/pin/voltage not confirmed: {row}")
            pull_rows.append(row)
        report["physical_row_pull_lines"] = pull_rows
        image = physical / "integrated_instrument_64.fs"
        target = root / "bitstream/integrated_instrument_64_row_pullup.fs"
        if target.exists():
            raise FileExistsError(target)
        unchanged()
        shutil.copy2(image, target)
        report.update(status="PASS", bitstream=str(target),
                      bitstream_sha256=sha(target), frozen_bitstream_preserved=True)
        for source in physical.iterdir():
            if source.suffix in (".html", ".io") or source.name.endswith(".rpt.txt"):
                shutil.copy2(source, output / source.name)
        print("PASS", target, report["bitstream_sha256"], flush=True)
    except BaseException as error:
        report.update(status="STOPPED", reason=repr(error))
        raise
    finally:
        runtime.KERNEL.SetThreadExecutionState(0x80000000)
        report["inputs_unchanged"] = all(sha(project / p) == h for p, h in inputs.items())
        report["frozen_bitstream_preserved"] = sha(frozen) == frozen_hash
        save()


if __name__ == "__main__":
    main()

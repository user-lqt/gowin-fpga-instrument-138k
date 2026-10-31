"""Verify frozen inputs; optionally compile the 64-voice top and focused RTL tests."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify():
    manifest = json.loads((ROOT / "package_manifest.json").read_text(encoding="utf-8"))
    for relative, expected in manifest["files"].items():
        path = ROOT / relative
        if not path.is_file() or sha(path) != expected:
            raise RuntimeError(f"Missing or modified package input: {relative}")
    print(f"PASS SHA256: {len(manifest['files'])} files", flush=True)
    for entry in (ROOT / "project").glob("*/*.gprj"):
        project = entry.parent
        paths = [project / f.attrib["path"] for f in ET.parse(entry).iter("File")]
        includes = [project / "source/rtl" / p for p in ("common", "input", "ui/new_screen")]
        for path in paths:
            if not path.resolve().is_relative_to(project.resolve()) or not path.is_file():
                raise RuntimeError(f"Missing or escaping project dependency: {path}")
        for path in (project / "source").rglob("*"):
            if path.suffix not in (".v", ".vh"):
                continue
            text = path.read_text(encoding="utf-8")
            for inc in re.findall(r'`include\s+"([^"]+)"', text):
                choices = [path.parent / inc, *[directory / inc for directory in includes]]
                if not any(p.is_file() and p.resolve().is_relative_to(project.resolve())
                           for p in choices):
                    raise RuntimeError(f"Unresolved include {inc}: {path}")
            for memory in re.findall(r'\$readmem[hb]\s*\(\s*"([^"]+)"', text):
                target = project / memory
                if not target.is_file() or not target.resolve().is_relative_to(project.resolve()):
                    raise RuntimeError(f"Missing or escaping ROM: {target}")
    print("PASS project/include/ROM dependency closure", flush=True)
    return manifest


def compile_tests(iv, vvp, output):
    output.mkdir(parents=True, exist_ok=False)
    results = {}

    def run(command, name, cwd, simulation=False):
        result = subprocess.run(list(map(str, command)), cwd=cwd,
                                capture_output=True, text=True, timeout=180)
        text = result.stdout + result.stderr
        (output / f"{name}.log").write_text(text, encoding="utf-8")
        if result.returncode or (simulation and ("PASS" not in text or "FATAL" in text)):
            raise RuntimeError(f"{name} failed; see {output / (name + '.log')}")
        results[name] = "PASS"
        print(f"PASS {name}", flush=True)

    for voices in (64,):
        name = f"integrated_instrument_{voices}"
        project = ROOT / "project" / name
        rtl = project / "source/rtl"
        inc = [item for p in ("common", "input", "ui/new_screen")
               for item in ("-I", rtl / p)]
        files = [project / f.attrib["path"]
                 for f in ET.parse(project / f"{name}.gprj").iter("File")
                 if f.attrib["path"].endswith(".v")]
        files = [project / "verification/clock_gen_stub.v"
                 if p.name == "clock_gen.v" else p for p in files]
        top = "instrument_64_top" if voices == 64 else "instrument_24_rgb_top"
        run([iv, "-g2012", "-s", top, *inc, "-o", output / f"top{voices}.vvp",
             *files], f"top{voices}_PLL_stub", project)
        tests = {
            "tb_wave_response": [rtl / "ui/waveform_buffer.v"],
            "tb_debounce15": [rtl / "input/keyboard_24_dual.v"],
            "tb_scan_debounce15": [rtl / "input/keyboard_24_dual.v",
                                    rtl / "input/keyboard_24_input.v",
                                    rtl / "input/matrix_scan_8x6.v"],
            "tb_acceptance_sweep": [rtl / "system/polyphony_test.v"],
        }
        if voices == 64:
            tests["tb_acceptance_default_timing"] = [rtl / "system/polyphony_test.v"]
            tests["tb_oscillator_state_bank"] = [
                rtl / "audio_core" / p for p in (
                    "oscillator_state_bank.v", "oscillator.v", "phase_acc.v", "wavetable.v")]
        for tb, sources in tests.items():
            exe = output / f"{tb}_{voices}.vvp"
            override = [f"-P{tb}.VOICES={voices}"] if tb == "tb_acceptance_sweep" else []
            run([iv, "-g2012", "-s", tb, *override, *inc, "-o", exe, *sources,
                 ROOT / "verification" / f"{tb}.v"], f"{tb}_{voices}_compile", project)
            run([vvp, exe], f"{tb}_{voices}", project, simulation=True)
    (output / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtl", action="store_true", help="Run full structural compile and focused tests")
    parser.add_argument("--iverilog", default=shutil.which("iverilog"))
    parser.add_argument("--vvp", default=shutil.which("vvp"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    verify()
    if args.rtl:
        if not args.iverilog or not args.vvp:
            parser.error("Install Icarus Verilog or specify --iverilog and --vvp")
        output = args.output or Path(tempfile.mkdtemp(prefix="instrument_check_")) / "results"
        compile_tests(args.iverilog, args.vvp, output.resolve())
        verify()
        print("Logs:", output)


if __name__ == "__main__":
    main()

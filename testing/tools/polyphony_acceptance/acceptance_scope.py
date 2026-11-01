"""DS2000A stopped acquisition capture and independent polyphony analysis.

Vendor: MSO2000A/DS2000A Programming Guide, 2-365, 2-367, 2-374.
Only WAV transfer settings change; acquisition controls are never written.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import socket
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from measurement_files import report_folder, screen_file
from capture_key_trial import block as read_scpi_block

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
FS = 48000
FFT_SIZE = 16384
BASE_BIN = 257
STEP_BIN = 32


def selected_voices(voices, selection):
    if voices not in (32, 64) or not 0 <= selection <= voices + 4:
        raise ValueError("voices must be 32/64; selection must be 0..voices+4")
    indices = np.arange(voices)
    if selection == 0:
        return np.ones(voices, dtype=bool)
    if selection <= 4:
        return indices // (voices // 4) == selection - 1
    return indices != selection - 5


def frequencies(voices):
    return (BASE_BIN + STEP_BIN * np.arange(voices)) * FS / FFT_SIZE


class Scope:
    def __init__(self, host, port=5555):
        self.sock = socket.create_connection((host, port), timeout=5)
        self.sock.settimeout(30)
        self.stream = self.sock.makefile("rb")

    def close(self):
        self.stream.close()
        self.sock.close()

    def send(self, command):
        self.sock.sendall((command + "\n").encode("ascii"))

    def query(self, command):
        self.send(command)
        answer = self.stream.readline(4096)
        if not answer.endswith(b"\n"):
            raise ValueError("Missing/oversized SCPI text response")
        return answer.decode("ascii").strip()

    def exact(self, count):
        data = bytearray()
        while len(data) < count:
            block = self.stream.read(count - len(data))
            if not block:
                raise EOFError("Scope disconnected during RAW transfer")
            data.extend(block)
        return bytes(data)

    def block(self, expected):
        if self.exact(1) != b"#":
            raise ValueError("Missing IEEE binary block header")
        digits = self.exact(1)
        if digits not in b"123456789":
            raise ValueError("Unsupported indefinite/invalid block")
        length = int(self.exact(int(digits)))
        if length != expected or length > 250000:
            raise ValueError(f"Expected {expected} BYTE points; received {length}")
        data = self.exact(length)
        if self.stream.readline(3) not in (b"\n", b"\r\n"):
            raise ValueError("Invalid binary block terminator")
        return data

    def block_bytes(self, limit):
        return read_scpi_block(self.stream, limit)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding="utf-8")


def create_trial_folder(root, voices, selection):
    selected_voices(voices, selection)
    label = ("all" if selection == 0 else f"group{selection:02d}"
             if selection <= 4 else f"mute{selection - 4:02d}")
    root = Path(root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    index = 1
    while True:
        folder = root / f"{label}_{voices}_{index:03d}"
        try:
            folder.mkdir()
            return folder
        except FileExistsError:
            index += 1


def capture(args):
    selected_voices(args.voices, args.selection)
    if args.channel not in (1, 2):
        raise ValueError("DS2202A analog channel must be 1 or 2")
    bitstream = Path(args.bitstream).resolve()
    if not bitstream.is_file():
        raise ValueError("Specify the bitstream actually loaded on the board")
    auto_folder = getattr(args, "auto_folder", False)
    requested_output = Path(args.output).resolve()
    output = None
    if not auto_folder and requested_output.exists():
        raise FileExistsError("Choose a new trial folder; existing trials are never overwritten")
    scope = Scope(args.ip, args.port)
    metadata = {
        "kind": "DAC_OUTPUT_SCOPE_CAPTURE",
        "operator_declared_voices": args.voices,
        "operator_declared_selection": args.selection,
        "operator_declared_bitstream": str(bitstream),
        "bitstream_sha256": hashlib.sha256(bitstream.read_bytes()).hexdigest(),
        "channel": args.channel,
        "host": args.ip,
        "complete": False,
        "note": "Identity/settings are operator declarations, not read back from FPGA.",
    }
    original = {}
    try:
        identity = scope.query("*IDN?")
        if "RIGOL" not in identity.upper() or "DS2202A" not in identity.upper():
            raise ValueError(f"Expected Rigol DS2202A, got {identity!r}")
        metadata["identity"] = identity
        if scope.query(":TRIG:STAT?") != "STOP":
            raise ValueError("Press RUN/STOP to stop a stable acquisition before capturing")
        if scope.query(f":CHAN{args.channel}:DISP?") not in ("1", "ON"):
            raise ValueError("Enable the requested channel before acquisition")
        for command in (":ACQ:MDEP?", ":ACQ:SRAT?", ":ACQ:TYPE?",
                        ":TIM:SCAL?", ":TIM:OFFS?"):
            metadata[command] = scope.query(command)
        if metadata[":ACQ:TYPE?"].upper() not in ("NORM", "NORMAL"):
            raise ValueError("Use Normal acquisition, not peak-detect/average/high-resolution")
        original = {key: scope.query(f":WAV:{key}?")
                    for key in ("SOUR", "MODE", "FORM", "STAR", "STOP")}
        scope.send(f":WAV:SOUR CHAN{args.channel}")
        scope.send(":WAV:MODE RAW")
        scope.send(":WAV:FORM BYTE")
        if scope.query(":WAV:MODE?") != "RAW" or scope.query(":WAV:FORM?") != "BYTE":
            raise ValueError("Scope did not accept RAW BYTE transfer")
        preamble = [float(x) for x in scope.query(":WAV:PRE?").split(",")]
        if len(preamble) != 10 or preamble[0] != 0 or preamble[1] != 2:
            raise ValueError("Unexpected RAW BYTE preamble")
        points = int(preamble[2])
        dt = preamble[4]
        if not np.all(np.isfinite(preamble)) or dt <= 0 or preamble[7] <= 0:
            raise ValueError("Invalid waveform scales")
        if not 16384 <= points <= 56000000:
            raise ValueError("Unexpected RAW point count")
        if (points - 1) * dt < FFT_SIZE / FS:
            raise ValueError("Capture at least 0.342 seconds; increase timebase/memory depth")
        if 1 / dt < FS:
            raise ValueError("Sampling rate below 48 kSa/s; increase memory depth")
        metadata["preamble"] = preamble
        metadata["original_transfer"] = original
        metadata["channel_settings"] = {
            key: scope.query(f":CHAN{args.channel}:{key}?")
            for key in ("SCAL", "OFFS", "PROB", "COUP", "BWL")
        }
        if auto_folder:
            output = create_trial_folder(requested_output, args.voices, args.selection)
        else:
            requested_output.mkdir(parents=True)
            output = requested_output
        print(f"Saving capture: {output}", flush=True)
        write_json(output / "capture.json", metadata)
        scope.send(":DISPlay:DATA?")
        screen = scope.block_bytes(20_000_000)
        if not screen.startswith(b"BM"):
            raise ValueError("示波器返回的原屏不是 BMP，原始记录保留为未完成。")
        screen_file(output, "polyphony", writing=True).write_bytes(screen)
        with (output / "raw.bin").open("xb") as target:
            for start in range(1, points + 1, 100000):
                stop = min(start + 99999, points)
                # Expand the old stop before advancing the next start.
                scope.send(f":WAV:STOP {stop}")
                scope.send(f":WAV:STAR {start}")
                if int(scope.query(":WAV:STAR?")) != start or int(scope.query(":WAV:STOP?")) != stop:
                    raise ValueError("Scope clamped transfer range")
                scope.send(":WAV:DATA?")
                target.write(scope.block(stop - start + 1))
                print(f"{stop}/{points} points", flush=True)
        error = scope.query(":SYST:ERR?")
        metadata["scope_error"] = error
        if int(error.split(",", 1)[0]) != 0:
            raise ValueError(f"Scope error: {error}")
        if scope.query(":TRIG:STAT?") != "STOP":
            raise ValueError("Acquisition changed during transfer; discard this trial")
        metadata["raw_sha256"] = hashlib.sha256((output / "raw.bin").read_bytes()).hexdigest()
        metadata["complete"] = True
    finally:
        restore_errors = []
        if original:
            for key in ("SOUR", "MODE", "FORM"):
                try:
                    scope.send(f":WAV:{key} {original[key]}")
                except OSError as error:
                    restore_errors.append(str(error))
            try:
                # Restore endpoints without transient start>stop combinations.
                scope.send(":WAV:STAR 1")
                scope.send(f":WAV:STOP {original['STOP']}")
                scope.send(f":WAV:STAR {original['STAR']}")
            except OSError as error:
                restore_errors.append(str(error))
            try:
                for key, expected in original.items():
                    actual = scope.query(f":WAV:{key}?")
                    if actual.upper() != expected.upper():
                        restore_errors.append(f"{key}: expected {expected}, got {actual}")
            except (OSError, ValueError, EOFError) as error:
                restore_errors.append(str(error))
        metadata["transfer_restore_errors"] = restore_errors
        scope.close()
        if output is not None and output.exists():
            write_json(output / "capture.json", metadata)
    if not metadata["complete"]:
        raise ValueError("Capture incomplete")
    if metadata["transfer_restore_errors"]:
        print("WARNING: waveform transfer settings could not be fully restored: " +
              "; ".join(metadata["transfer_restore_errors"]), file=sys.stderr)
    print(output)
    return output


def analyze_samples(samples, sample_rate, voices, selection, source_kind, clipped=False):
    """FFT of a contiguous Hann-windowed record; no peak count from UI flags."""
    expected = selected_voices(voices, selection)
    samples = np.asarray(samples, dtype=float)
    if samples.ndim != 1 or samples.size < 16384 or not np.all(np.isfinite(samples)):
        raise ValueError("Need at least 16384 finite mono samples")
    if not np.isfinite(sample_rate) or sample_rate < FS:
        raise ValueError("Need known sample rate >=48 kSa/s")
    if (samples.size - 1) / sample_rate < (FFT_SIZE - 1) / FS:
        raise ValueError("Record too short to resolve independent tones")
    # No decimation: retain the captured anti-alias boundary and physical duration.
    # A larger FFT when the scope samples faster is necessary to retain resolution.
    nfft = 1 << (samples.size - 1).bit_length()
    if nfft > 2**27:
        raise ValueError("Record exceeds bounded FFT memory")
    window = np.hanning(samples.size)
    signal = (samples - samples.mean()) * window
    magnitude = np.abs(np.fft.rfft(signal, n=nfft)) * (2 / window.sum())
    hz = np.fft.rfftfreq(nfft, 1 / sample_rate)
    targets = frequencies(voices)
    # Fit a common clock ratio. The same physical clocks set every test tone.
    scales = np.linspace(0.998, 1.002, 801)
    active_targets = targets[expected]
    scores = np.array([np.log(np.maximum(
        np.interp(active_targets * scale, hz, magnitude), 1e-20)).sum()
        for scale in scales])
    scale = float(scales[int(np.argmax(scores))])
    width = max(2 * sample_rate / samples.size, 4.0)
    if width >= STEP_BIN * FS / FFT_SIZE / 4:
        raise ValueError("Record too short for separated peak guards")
    rows = []
    guard = np.zeros(hz.size, dtype=bool)
    for index, target in enumerate(targets * scale):
        region = np.abs(hz - target) <= width
        if not region.any():
            raise ValueError("No FFT bins near expected tone")
        bins = np.flatnonzero(region)
        peak_bin = bins[int(np.argmax(magnitude[bins]))]
        guard |= np.abs(hz - target) <= width * 2
        rows.append({
            "voice": index + 1, "enabled": bool(expected[index]),
            "nominal_hz": float(targets[index]), "predicted_hz": float(target),
            "measured_hz": float(hz[peak_bin]),
            "amplitude_peak": float(magnitude[peak_bin]),
        })
    amplitudes = np.array([row["amplitude_peak"] for row in rows])
    reference = float(np.median(amplitudes[expected]))
    in_band = (hz >= max(20, targets[0] - 100)) & (hz <= targets[-1] + 100)
    noise_bins = magnitude[in_band & ~guard]
    noise = float(np.median(noise_bins)) if noise_bins.size else 0
    threshold = max(reference * 10**(-12 / 20), noise * 10**(15 / 20), 1e-15)
    for row in rows:
        amplitude = row["amplitude_peak"]
        row["relative_db"] = float(20 * np.log10(max(amplitude, 1e-20) / max(reference, 1e-20)))
        row["snr_db"] = float(20 * np.log10(max(amplitude, 1e-20) / max(noise, 1e-20)))
        row["present"] = amplitude >= threshold
        row["match"] = row["present"] == row["enabled"]
    unwanted = magnitude[(hz >= 20) & (hz <= min(20000, sample_rate / 2)) & ~guard]
    spur = float(unwanted.max()) if unwanted.size else 0
    result = {
        "source": source_kind, "voices": voices, "selection": selection,
        "expected_peaks": int(expected.sum()),
        "matched_enabled_peaks": sum(row["present"] and row["enabled"] for row in rows),
        "unexpected_enabled_targets": sum(row["present"] and not row["enabled"] for row in rows),
        "sample_rate_hz": sample_rate, "samples": samples.size, "fft_size": nfft,
        "record_seconds": samples.size / sample_rate,
        "bin_spacing_hz": sample_rate / nfft,
        "clock_ratio": scale, "clock_fit_at_boundary": scale in (scales[0], scales[-1]),
        "window": "Hann, full contiguous record, zero padded only",
        "amplitude_reference": "median enabled tone peak; not dBFS",
        "clipped": bool(clipped),
        "largest_non_target_db": float(20 * np.log10(max(spur, 1e-20) / max(reference, 1e-20))),
        "rows": rows,
        "caution": "Spectral evidence is not by itself proof of independent RTL states.",
    }
    result["spectral_check"] = ("PASS" if all(row["match"] for row in rows)
                                and reference > 1e-12 and not clipped
                                and not result["clock_fit_at_boundary"]
                                and result["largest_non_target_db"] < -12 else "FAIL")
    return result, hz, magnitude


def analyze_capture(folder):
    folder = Path(folder).resolve()
    metadata = json.loads((folder / "capture.json").read_text(encoding="utf-8"))
    if metadata.get("kind") != "DAC_OUTPUT_SCOPE_CAPTURE" or not metadata.get("complete"):
        raise ValueError("Not a complete hardware scope capture")
    raw = (folder / "raw.bin").read_bytes()
    if hashlib.sha256(raw).hexdigest() != metadata["raw_sha256"]:
        raise ValueError("RAW hash mismatch")
    pre = metadata["preamble"]
    if len(raw) != int(pre[2]):
        raise ValueError("RAW size/preamble mismatch")
    codes = np.frombuffer(raw, dtype=np.uint8)
    voltage = (codes.astype(float) - pre[9] - pre[8]) * pre[7]
    clipped = bool(np.any(codes <= 1) or np.any(codes >= 254))
    result, hz, magnitude = analyze_samples(
        voltage, 1 / pre[4], metadata["operator_declared_voices"],
        metadata["operator_declared_selection"], metadata["kind"], clipped)
    result["capture_sha256"] = metadata["raw_sha256"]
    result["bitstream_sha256"] = metadata["bitstream_sha256"]
    save_report(folder, result, hz, magnitude)
    return result


def compare_captures(baseline, changed):
    baseline, changed = Path(baseline).resolve(), Path(changed).resolve()
    full = analyze_capture(baseline)
    trial = analyze_capture(changed)
    if full["selection"] != 0 or trial["selection"] < 5:
        raise ValueError("Select ALL as baseline and MUTE as the changed trial")
    if full["voices"] != trial["voices"] or full["bitstream_sha256"] != trial["bitstream_sha256"]:
        raise ValueError("Trials must declare the same bitstream and voice configuration")
    before = np.array([row["amplitude_peak"] for row in full["rows"]])
    after = np.array([row["amplitude_peak"] for row in trial["rows"]])
    enabled = np.array([row["enabled"] for row in trial["rows"]])
    ratios = after / np.maximum(before, 1e-20)
    # Allow a common analog gain change, but report it separately and limit it.
    gain = float(np.median(ratios[enabled]))
    relative = 20 * np.log10(np.maximum(ratios / max(gain, 1e-20), 1e-20))
    gain_db = float(20 * np.log10(max(gain, 1e-20)))
    checks = []
    for i, db in enumerate(relative):
        checks.append({"voice": i + 1, "enabled": bool(enabled[i]),
                       "normalized_change_db": float(db),
                       "match": bool(abs(db) <= 3 if enabled[i] else db <= -20)})
    result = {
        "source": ("DAC_OUTPUT_SCOPE_COMPARISON"
                   if full["source"] == trial["source"] == "DAC_OUTPUT_SCOPE_CAPTURE"
                   else "NON_DAC_COMPARISON"),
        "baseline": str(baseline), "changed": str(changed),
        "bitstream_sha256": full["bitstream_sha256"],
        "common_gain_change_db": gain_db,
        "comparison": ("PASS" if full["spectral_check"] == "PASS"
                       and trial["spectral_check"] == "PASS"
                       and abs(gain_db) <= 3 and all(row["match"] for row in checks) else "FAIL"),
        "rows": checks,
    }
    write_json(report_folder(changed, "polyphony") / "comparison.json", result)
    from acceptance_reports import save_comparison
    save_comparison(report_folder(baseline, "polyphony"), report_folder(changed, "polyphony"), full, trial, result)
    return result


def save_report(folder, result, hz, magnitude):
    from acceptance_reports import save_details, save_overview
    folder = report_folder(folder, "polyphony")
    folder.mkdir(parents=True, exist_ok=True)
    write_json(folder / "analysis.json", result)
    with (folder / "peaks.csv").open("w", newline="", encoding="utf-8-sig") as target:
        writer = csv.DictWriter(target, fieldnames=list(result["rows"][0]))
        writer.writeheader()
        writer.writerows(result["rows"])
    save_overview(folder, result, hz, magnitude)
    save_details(folder, result, hz, magnitude)
    print(f"Report: {folder / 'report.html'}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    cap = commands.add_parser("capture")
    cap.add_argument("--ip", required=True)
    cap.add_argument("--port", type=int, default=5555)
    cap.add_argument("--channel", type=int, choices=[1, 2], default=1)
    cap.add_argument("--voices", type=int, choices=[32, 64], required=True)
    cap.add_argument("--selection", type=int, default=0)
    cap.add_argument("--bitstream", required=True)
    cap.add_argument("--output", required=True)
    cap.add_argument("--auto-folder", action="store_true",
                     help="Treat --output as a root; create numbered trial subfolders")
    analysis = commands.add_parser("analyze")
    analysis.add_argument("folder")
    compare = commands.add_parser("compare")
    compare.add_argument("baseline")
    compare.add_argument("changed")
    args = parser.parse_args()
    if args.command == "compare":
        result = compare_captures(args.baseline, args.changed)
        print(json.dumps(result, indent=2))
        return 0 if result["comparison"] == "PASS" else 2
    if args.command == "capture":
        folder = capture(args)
    else:
        folder = args.folder
    result = analyze_capture(folder)
    print(json.dumps({key: value for key, value in result.items() if key != "rows"}, indent=2))
    return 0 if result["spectral_check"] == "PASS" else 2


if __name__ == "__main__":
    sys.exit(main())

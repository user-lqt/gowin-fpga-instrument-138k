"""Measure reference FLACs, exporting parameters only (never reference PCM)."""
import argparse
import json
import re
import subprocess
from pathlib import Path

import numpy as np


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("samples", type=Path)
    parser.add_argument("--ffmpeg", required=True)
    args = parser.parse_args()
    rows = []
    semitones = {"C": 0, "D": 2, "F": 5, "A": 9, "B": 11}
    for path in sorted(args.samples.glob("*.flac")):
        match = re.fullmatch(r"([CDFAB])(#?)(\d)v([HL])", path.stem)
        if not match:
            continue
        letter, sharp, octave, velocity = match.groups()
        note = (int(octave) + 1) * 12 + semitones[letter] + bool(sharp)
        f0 = 440 * 2 ** ((note - 69) / 12)
        process = subprocess.run(
            [args.ffmpeg, "-v", "error", "-i", str(path), "-ac", "1",
             "-ar", "48000", "-f", "f32le", "pipe:1"],
            check=True, capture_output=True)
        audio = np.frombuffer(process.stdout, dtype="<f4").astype(float)
        # Normalize each sample only for shape comparisons, not loudness.
        peak = float(np.max(np.abs(audio)))
        audio /= max(peak, 1e-12)
        rms = []
        for time in (0.05, 0.15, 0.30, 0.50, 1.0, 2.0):
            segment = audio[int(time * 48000):int((time + 0.1) * 48000)]
            rms.append(float(np.sqrt(np.mean(segment ** 2))) if len(segment) else None)
        segment = audio[3840:15840]
        spectrum = np.abs(np.fft.rfft(segment * np.hanning(len(segment))))
        frequency = np.fft.rfftfreq(len(segment), 1 / 48000)
        partials = []
        for harmonic in range(1, 13):
            # Search wide enough for lightly stretched piano partials.
            band = np.abs(frequency - f0 * harmonic) < max(4, f0 * harmonic * 0.004)
            partials.append(float(np.max(spectrum[band])) if band.any() else 0)
        denominator = max(partials[0], 1e-12)
        rows.append(dict(file=path.name, note=note, velocity_layer=velocity,
                         duration_seconds=len(audio) / 48000, source_peak=peak,
                         normalized_rms=rms,
                         partial_ratios=[p / denominator for p in partials]))
    output = Path(__file__).parent / "build/iverilog/waveforms/piano_reference_analysis.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(rows, indent=2, allow_nan=False), encoding="ascii")
    print(f"Analyzed {len(rows)} files; parameters only: {output}")


if __name__ == "__main__":
    main()

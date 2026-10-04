"""Analyze a user-owned performance without embedding its PCM into HDL."""
import argparse
import json
import subprocess
from pathlib import Path

import imageio_ffmpeg
import numpy as np
from scipy.signal import find_peaks, stft

RATE = 48000


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("video", type=Path)
    args = parser.parse_args()
    result = subprocess.run([
        imageio_ffmpeg.get_ffmpeg_exe(), "-v", "error", "-i", str(args.video),
        "-vn", "-ac", "1", "-ar", str(RATE), "-f", "f32le", "pipe:1"],
        check=True, capture_output=True)
    audio = np.frombuffer(result.stdout, dtype="<f4").astype(float)
    freq, time, spectrum = stft(audio, RATE, nperseg=2048, noverlap=1536)
    power = np.abs(spectrum) ** 2
    flux = np.sum(np.maximum(np.diff(np.log1p(power * 1e6), axis=1), 0), axis=0)
    onsets, _ = find_peaks(flux, distance=12, prominence=np.std(flux))
    ranked = sorted(onsets, key=lambda i: flux[i], reverse=True)[:12]
    events = []
    for index in sorted(ranked):
        start = time[index + 1]
        early = power[:, index + 1:index + 5].mean(axis=1)
        late = power[:, index + 9:index + 17].mean(axis=1)
        if not np.any(late):
            continue
        centroid = lambda p: float(np.sum(freq * p) / max(p.sum(), 1e-20))
        band_peaks, _ = find_peaks(early, distance=3)
        dominant = sorted(band_peaks, key=lambda i: early[i], reverse=True)[:6]
        events.append({
            "seconds": round(float(start), 3),
            "early_centroid_hz": round(centroid(early), 1),
            "late_centroid_hz": round(centroid(late), 1),
            "dominant_bins_hz": [round(float(freq[i]), 1) for i in dominant],
        })
    report = {
        "duration_seconds": round(len(audio) / RATE, 3),
        "sample_rate": RATE,
        "notes": "Polyphonic performance; centroids include overlapping notes. "
                 "Not an isolated body impulse response or listening evaluation.",
        "onset_candidates": events,
    }
    out = Path(__file__).parent / "build/iverilog/waveforms/guitar_reference_analysis.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

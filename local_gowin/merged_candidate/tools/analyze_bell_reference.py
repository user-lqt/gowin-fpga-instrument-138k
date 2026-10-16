"""Measure a supplied bell recording; export measurements, never PCM to HDL."""
import argparse
import json
from pathlib import Path
import subprocess

import imageio_ffmpeg
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy.signal import find_peaks, stft


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("video", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    rate = 24000
    process = subprocess.run(
        [imageio_ffmpeg.get_ffmpeg_exe(), "-v", "error", "-i", str(args.video),
         "-vn", "-ac", "1", "-ar", str(rate), "-f", "f32le", "pipe:1"],
        capture_output=True, check=True)
    audio = np.frombuffer(process.stdout, dtype="<f4").astype(float)
    frequency, times, spectrum = stft(audio, rate, nperseg=2048, noverlap=1792)
    power = np.abs(spectrum) ** 2
    flux = np.maximum(np.diff(np.abs(spectrum), axis=1), 0).sum(axis=0)
    candidates, properties = find_peaks(
        flux, distance=20, prominence=max(np.std(flux) * 0.7, 1e-6))
    events = []
    for candidate in candidates:
        time = float(times[candidate + 1])
        segment = audio[int((time + 0.025) * rate):int((time + 0.24) * rate)]
        if len(segment) < 1000:
            continue
        amplitude = np.abs(np.fft.rfft(segment * np.hanning(len(segment)), n=131072))
        bins = np.fft.rfftfreq(131072, 1 / rate)
        peaks, _ = find_peaks(amplitude, distance=25)
        peaks = [i for i in peaks if 120 < bins[i] < 9000]
        peaks = sorted(peaks, key=lambda i: amplitude[i], reverse=True)[:16]
        reference = max(amplitude[peaks[0]], 1e-12)
        events.append({
            "seconds": round(time, 3),
            "strength": round(float(flux[candidate]), 4),
            "partials": [
                [round(float(bins[i]), 2), round(float(amplitude[i] / reference), 3)]
                for i in peaks
            ],
        })
    report = {
        "source": str(args.video),
        "duration": len(audio) / rate,
        "warning": "Repeated strikes and room sound overlap; peaks are candidates, not isolated modes.",
        "events": events,
    }
    (args.output / "reference_analysis.json").write_text(
        json.dumps(report, indent=2), encoding="ascii")
    np.save(args.output / "reference_analysis_audio.npy", audio)
    fig, axes = plt.subplots(3, 1, figsize=(16, 10), constrained_layout=True)
    axes[0].plot(np.arange(len(audio))[::48] / rate, audio[::48], linewidth=0.5)
    axes[0].set(ylabel="Amplitude", xlim=(0, len(audio) / rate))
    axes[1].pcolormesh(times, frequency, 10 * np.log10(power + 1e-12),
                       vmin=-80, vmax=-25, shading="auto", cmap="magma")
    axes[1].set(ylim=(0, 6000), ylabel="Hz")
    axes[2].plot(times[1:], flux)
    axes[2].scatter(times[candidates + 1], flux[candidates], s=10, color="red")
    axes[2].set(xlabel="Seconds", ylabel="Spectral onset flux")
    fig.savefig(args.output / "reference_overview.png", dpi=140)
    print(json.dumps({"duration": report["duration"], "onset_count": len(events),
                      "strong_events": sorted(events, key=lambda e: e["strength"], reverse=True)[:12]},
                     indent=2))


if __name__ == "__main__":
    main()

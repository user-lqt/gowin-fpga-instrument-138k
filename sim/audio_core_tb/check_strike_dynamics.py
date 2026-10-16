"""Validate HDL captures without per-strike loudness normalization."""
from pathlib import Path
import csv
import json
import wave

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = Path(__file__).parent / "build/iverilog/waveforms"
RATE = 48000


def wav(path, pcm):
    # One common gain for every audition, preserving soft/hard relationships.
    audio = np.clip(np.asarray(pcm) * 8, -8388608, 8388607).astype(np.int32)
    with wave.open(str(path), "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(3)
        stream.setframerate(RATE)
        stream.writeframes(b"".join(int(x).to_bytes(4, "little", signed=True)[:3]
                                   for x in audio))


def main():
    tracks = {}
    with (OUT / "strike_dynamics.csv").open(newline="") as stream:
        for row in csv.DictReader(stream):
            key = (int(row["instrument"]), int(row["velocity"]))
            track = tracks.setdefault(key, [])
            assert int(row["index"]) == len(track), "missing PCM frame"
            track.append(int(row["sample"]))
    names = ("piano", "guitar", "bianzhong")
    fig, axes = plt.subplots(3, 2, figsize=(12, 8), constrained_layout=True)
    metrics = {}
    for timbre, name in enumerate(names):
        energies, spectra, high_ratios = [], [], []
        audition = []
        for velocity in (32, 80, 120):
            pcm = np.asarray(tracks[(timbre, velocity)], dtype=float)
            assert len(pcm) == 16384
            assert np.max(np.abs(pcm)) < 8388607, "clipped PCM"
            segment = pcm[1024:8192]
            rms = float(np.sqrt(np.mean(segment**2)))
            assert rms > 0
            power = np.abs(np.fft.rfft((segment-segment.mean()) *
                                      np.hanning(len(segment))))**2
            frequencies = np.fft.rfftfreq(len(segment), 1/RATE)
            fundamental = (frequencies >= 420) & (frequencies <= 460)
            peak = float(frequencies[fundamental][np.argmax(power[fundamental])])
            assert abs(peak-440) <= RATE/len(segment), "A4 tuning moved"
            assert power[fundamental].max() > power.max()*0.05, "A4 fundamental missing"
            normalized = power / power.sum()
            high = float(normalized[frequencies >= 2000].sum())
            energies.append(rms)
            spectra.append(np.sqrt(normalized))
            high_ratios.append(high)
            metrics[f"{name}_{velocity}"] = {
                "rms": rms, "high_band_fraction": high, "fundamental_peak_hz": peak}
            axes[timbre, 0].plot(np.arange(len(pcm))/RATE, pcm, label=str(velocity))
            axes[timbre, 1].plot(frequencies,
                                10*np.log10(np.maximum(normalized, 1e-12)),
                                label=str(velocity))
            if timbre != 2:
                assert np.all(pcm[14000:] == 0), "damper release not silent"
            audition.extend((pcm, np.zeros(12000)))
        assert energies[0] < energies[1] < energies[2], (name, energies)
        distance = float(np.linalg.norm(spectra[2]-spectra[0]))
        assert distance > 0.015, f"{name}: only amplitude changed"
        assert high_ratios[2] > high_ratios[0], (name, high_ratios)
        metrics[f"{name}_normalized_spectral_distance"] = distance
        wav(OUT / f"{name}_velocity.wav", np.concatenate(audition))
        axes[timbre, 0].axvline(8192/RATE, color="black", linestyle="--")
        axes[timbre, 0].set(title=name, xlabel="Time (s)", ylabel="Raw PCM")
        axes[timbre, 0].legend()
        axes[timbre, 1].set(xlim=(0, 10000), ylim=(-100, 0),
                           xlabel="Frequency (Hz)", ylabel="Normalized power (dB)")
        print(f"PASS {name}: RMS {energies}, high band {high_ratios}, distance {distance:.4f}")
    with (OUT / "bell_tap.csv").open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    tapped = np.asarray([int(row["tapped"]) for row in rows], dtype=float)
    held = np.asarray([int(row["held"]) for row in rows], dtype=float)
    assert len(tapped) == 48000 and np.array_equal(tapped, held)
    early = float(np.sqrt(np.mean(tapped[1000:9000]**2)))
    tail = float(np.sqrt(np.mean(tapped[40000:48000]**2)))
    assert early > tail > 0, "bell natural decay missing"
    metrics["bell_tap_rms"] = {"early": early, "after_0_83s": tail}
    wav(OUT / "bianzhong_tap_tail.wav", tapped)
    fig.savefig(OUT / "strike_dynamics.png", dpi=150)
    plt.close(fig)
    # Exhaust every input to the narrowed displacement divider.
    for position in range(65536):
        old = ((position*2-16384) if position < 16384 else
               ((65535-position)*2//3-16384)) >> 5
        new = ((position >> 4) if position < 16384 else
               (((65535-position)*2 >> 5)//3)) - 512
        assert old == new, position
    metrics["displacement_exact_inputs"] = 65536
    (OUT / "strike_dynamics_metrics.json").write_text(json.dumps(metrics, indent=2))
    print("PASS: 65536 displacement inputs bit-exact; 48000 bell tap/hold frames identical")


if __name__ == "__main__":
    main()

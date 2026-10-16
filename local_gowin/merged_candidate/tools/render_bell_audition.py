"""Package actual HDL modal/envelope output, not a Python synthesizer."""
import json
from pathlib import Path
import wave

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


BUILD = Path(__file__).resolve().parents[1] / "sim" / "merged_checks"
RATE = 48000


def write_wav(name, samples):
    with wave.open(str(BUILD / name), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(samples.astype("<i2").tobytes())


def main():
    stems = np.loadtxt(BUILD / "bell_stems.csv", delimiter=",", dtype=np.int64)
    if stems.shape != (int(RATE * 4.2), 6):
        raise ValueError("Incomplete six-note RTL capture")
    if np.any(stems[int(RATE * 4.1) :]):
        raise ValueError("A stem did not become naturally silent")
    if np.any(np.sum(stems[int(RATE * 1.6):int(RATE * 1.7)].astype(float)**2, axis=0)==0):
        raise ValueError("A bell lost its tail at the previous overwrite point")
    raw = np.zeros(RATE * 15, dtype=np.int64)
    raw[int(RATE * 0.2):int(RATE * 0.2) + len(stems)] += stems[:, 0]
    # Sum complete RTL strikes. No resampling, synthesized oscillator, reverb,
    # per-note normalization, or four-lane cyclic retrigger is used here.
    melody = [0, 0, 4, 4, 5, 5, 4, 3, 3, 2, 2, 1, 1, 0]
    for index, column in enumerate(melody):
        start = RATE * 5 + index * 19200
        raw[start:start + len(stems)] += stems[:, column]
    if not np.any(raw):
        raise ValueError("Silent RTL capture")
    overlap = np.zeros(RATE * 6, dtype=np.int64)
    for index, column in enumerate((0, 4, 2)):
        start = int(RATE * 0.2) + index * 19200
        overlap[start:start + len(stems)] += stems[:, column]
    peak = max(int(np.max(np.abs(raw))), int(np.max(np.abs(overlap))))
    # One gain for both clips, not per-note normalization or added reverb.
    gain = 0.9 * 32767 / peak
    pcm = np.rint(raw * gain).astype(np.int16)
    write_wav("bell_full_tail_tap.wav", pcm[: RATE * 5])
    write_wav("bell_full_tail_twinkle.wav", pcm[RATE * 5 : RATE * 15])
    demonstration = np.rint(overlap * gain)
    if np.max(np.abs(demonstration)) > 32767:
        raise ValueError("Overlap demonstration exceeds common-gain headroom")
    write_wav("bell_tail_overlap_demo.wav", demonstration.astype(np.int16))
    if np.any(raw[int(RATE * 4.3) : RATE * 5]):
        raise ValueError("Single bell failed to become silent")
    if np.any(raw[int(RATE * 14.5) :]):
        raise ValueError("Melody tail failed to become silent")
    rms = {}
    onset = int(0.2 * RATE)
    for time in (0.05, 0.1, 0.25, 0.5, 1.0, 1.5, 1.9, 2.5, 3.5):
        start = onset + int(time * RATE)
        window = raw[start : start + int(0.05 * RATE)].astype(float)
        rms[str(time)] = float(np.sqrt(np.mean(window * window)))
    if not (rms["0.1"] > rms["0.5"] > rms["1.0"] > rms["1.5"]):
        raise ValueError("Measured single-hit RMS does not decay")
    if rms["2.5"] < rms["0.1"] * 0.005:
        raise ValueError("Body resonance decays too soon")
    def spectral_metrics(signal, start_seconds):
        start = onset + int(start_seconds * RATE)
        window = signal[start : start + int(0.15 * RATE)].astype(float)
        power = np.abs(np.fft.rfft(window * np.hanning(len(window)))) ** 2
        bins = np.fft.rfftfreq(len(window), 1 / RATE)
        return {
            "power_centroid_hz": float(np.sum(power * bins) / np.sum(power)),
            "power_above_1khz_fraction": float(power[bins > 1000].sum() / power.sum()),
        }
    brightness = {
        "attack": spectral_metrics(raw, 0.02),
        "tail": spectral_metrics(raw, 0.5),
    }
    if brightness["attack"]["power_centroid_hz"] < 1200:
        raise ValueError("Attack remains low-frequency dominated")
    if brightness["tail"]["power_centroid_hz"] < 1000:
        raise ValueError("Bright body lost during tail")
    previous = BUILD.parents[3] / "tmp/team_merge/bell_before_brightness/bell_audition.csv"
    if previous.exists():
        before = np.loadtxt(previous, dtype=np.int64)
        brightness["previous_attack"] = spectral_metrics(before, 0.02)
        brightness["previous_tail"] = spectral_metrics(before, 0.5)
    expected = 523.2511306 * np.array(
        [4096, 8192, 10962, 15044, 21092, 25102, 28824, 29480]) / 4096
    attack = raw[onset + 96 : onset + 9600].astype(float)
    amplitude = np.abs(np.fft.rfft(attack * np.hanning(len(attack)), n=131072))
    frequencies = np.fft.rfftfreq(131072, 1 / RATE)
    peaks = []
    for frequency in expected:
        selected = np.flatnonzero(np.abs(frequencies - frequency) < 8)
        index = selected[np.argmax(amplitude[selected])]
        measured = float(frequencies[index])
        if abs(measured - frequency) > 3:
            raise ValueError(f"Missing reference-guided mode near {frequency:.1f} Hz")
        peaks.append(measured)
    fig, axes = plt.subplots(2, 1, figsize=(10, 6), constrained_layout=True)
    times = np.array([float(t) for t in rms])
    values = np.array(list(rms.values()))
    axes[0].plot(times, 20 * np.log10(np.maximum(values, 1e-9) / values[0]), "o-")
    axes[0].set(xlabel="Seconds after strike", ylabel="RMS relative to 50 ms (dB)",
                title="Actual RTL bell: natural resonance without added reverb")
    axes[0].grid(alpha=0.25)
    selected = frequencies < 4200
    axes[1].plot(frequencies[selected],
                 20 * np.log10(np.maximum(amplitude[selected], 1) / amplitude.max()))
    for frequency in expected:
        axes[1].axvline(frequency, color="crimson", alpha=0.3)
    axes[1].set(xlabel="Frequency (Hz)", ylabel="Relative magnitude (dB)",
                ylim=(-90, 3), title="C5 attack modes; lines show intended frequencies")
    fig.savefig(BUILD / "bell_validation.png", dpi=150)
    plt.close(fig)
    report = {
        "sample_rate": RATE,
        "source": "Six complete RTL bianzhong_ram_bank + adsr_state_bank stems, offline linear overlap",
        "excluded": "Production allocator/mixer/FX/I2S; physical DAC and listening acceptance",
        "melody_strikes": len(melody),
        "tail_overwrite": False,
        "overlap_demo_seconds": 6,
        "common_wav_gain": gain,
        "raw_peak": peak,
        "rms_by_seconds_after_strike": rms,
        "measured_attack_mode_hz": peaks,
        "brightness": brightness,
        "tap_seconds": 5,
        "twinkle_seconds": 10,
    }
    (BUILD / "bell_audition_report.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="ascii"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

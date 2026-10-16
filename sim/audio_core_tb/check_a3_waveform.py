"""Analyze the long A3 capture and export three PCM WAV audition files."""

from pathlib import Path
import csv
import wave

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


ROOT = Path(__file__).parent
TRACE = ROOT / "build" / "iverilog" / "waveforms" / "a3_audition.csv"
OUT = ROOT / "build" / "iverilog" / "waveforms"
SAMPLE_RATE = 48_000
EXPECTED = 440.0


def read_trace():
    tracks = {0: [], 1: [], 2: []}
    with TRACE.open(newline="") as stream:
        for row in csv.DictReader(stream):
            tracks[int(row["scenario"].replace("timbre", ""))].append(int(row["audio"]))
    return {key: np.asarray(value, dtype=np.int32) for key, value in tracks.items()}


def write_wav(path, samples):
    clipped = np.clip(samples, -8388608, 8388607).astype(np.int32)
    raw = bytearray()
    for value in clipped:
        raw.extend(int(value).to_bytes(4, "little", signed=True)[:3])
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(3)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(raw)


def main():
    if not TRACE.exists():
        raise SystemExit(f"missing capture: {TRACE}")
    tracks = read_trace()
    spectra = {}
    fig, axes = plt.subplots(3, 2, figsize=(12, 8), constrained_layout=True)
    names = ("Upright piano", "Acoustic guitar", "Bianzhong")
    for timbre, samples in tracks.items():
        if timbre != 2 and len(samples) != 31200:
            raise AssertionError(f"timbre {timbre}: expected 31200 samples, got {len(samples)}")
        if timbre == 2 and not 290400 <= len(samples) <= 290500:
            raise AssertionError(f"bell: unexpected natural lifetime {len(samples)}")
        if np.any(samples[-2400:] != 0):
            raise AssertionError(f"timbre {timbre}: nonzero silent tail")
        if np.max(np.abs(samples)) >= 8388607:
            raise AssertionError(f"timbre {timbre}: clipped PCM")
        if np.max(np.abs(samples)) == 0:
            raise AssertionError(f"timbre {timbre}: silent capture")
        analysis = samples[4096:12288].astype(float)
        window = np.hanning(len(analysis))
        spectrum = np.abs(np.fft.rfft((analysis - analysis.mean()) * window))
        freq = np.fft.rfftfreq(len(analysis), 1 / SAMPLE_RATE)
        search = (freq >= EXPECTED - 20) & (freq <= EXPECTED + 20)
        peak = float(freq[search][np.argmax(spectrum[search])])
        spectra[timbre] = spectrum / np.linalg.norm(spectrum)
        if abs(peak - EXPECTED) > SAMPLE_RATE / len(analysis):
            raise AssertionError(f"timbre {timbre}: A4 peak is {peak:.2f} Hz")
        if spectrum[search].max() < spectrum.max() * 0.1:
            raise AssertionError(f"timbre {timbre}: A4 fundamental too weak")
        wav_path = OUT / f"a3_timbre_{timbre}.wav"
        write_wav(wav_path, samples)
        axes[timbre, 0].plot(np.arange(len(samples)) / SAMPLE_RATE, samples / 8388608)
        axes[timbre, 0].axvline(0.5, color="red", linestyle="--")
        axes[timbre, 0].set(title=names[timbre], xlabel="Time (s)", ylabel="PCM / full scale")
        axes[timbre, 1].plot(freq, 20 * np.log10(np.maximum(spectrum / spectrum.max(), 1e-6)))
        axes[timbre, 1].set(xlim=(0, 5000), ylim=(-90, 5), xlabel="Frequency (Hz)", ylabel="Relative dB")
        print(f"PASS: timbre {timbre} A4 peak {peak:.2f} Hz -> {wav_path.name}")

    differences = []
    for left in range(3):
        for right in range(left + 1, 3):
            differences.append(float(np.linalg.norm(spectra[left] - spectra[right])))
    if not all(value > 0.05 for value in differences):
        raise AssertionError(f"timbre spectra are too similar: {differences}")
    fig.savefig(OUT / "a3_waveform_spectrum.png", dpi=150)
    plt.close(fig)
    silence = np.zeros(12000, dtype=np.int32)
    write_wav(OUT / "a3_timbres_compare.wav",
              np.concatenate([np.concatenate((tracks[t], silence)) for t in range(3)]))
    print(f"PASS: gain-normalized spectral distances {differences}")
    print("A3 waveform PASS: 8192-point FFT per timbre, natural bell tail, 3 WAVs + comparison + plot")


if __name__ == "__main__":
    main()

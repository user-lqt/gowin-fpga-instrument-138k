"""Export unnormalized RTL PCM; compare identical piano/guitar notes."""
from pathlib import Path
import csv
import wave
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = Path(__file__).parent / "build" / "iverilog" / "waveforms"
RATE = 48000


def wav(path, samples):
    with wave.open(str(path), "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(3)
        stream.setframerate(RATE)
        stream.writeframes(b"".join(int(v).to_bytes(4, "little", signed=True)[:3]
                                   for v in samples))


def main():
    tracks = {(t, s): [] for t in (0, 3) for s in (0, 1)}
    with (OUT / "guitar_audition.csv").open(newline="") as stream:
        for row in csv.DictReader(stream):
            key = int(row["instrument"]), int(row["segment"])
            if int(row["index"]) != len(tracks[key]):
                raise AssertionError("non-contiguous sample indices")
            tracks[key].append(int(row["audio"]))
    tracks = {k: np.asarray(v, dtype=np.int32) for k, v in tracks.items()}
    fig, axes = plt.subplots(2, 2, figsize=(12, 6), constrained_layout=True)
    spectra = {}
    attack_harmonics = {}
    exports = {}
    for row, (t, name) in enumerate(((0, "piano"), (3, "guitar"))):
        for segment, length in ((0, 43200), (1, 38400)):
            samples = tracks[t, segment]
            assert len(samples) == length, (t, segment, len(samples))
            assert 0 < np.max(np.abs(samples)) < 8388607
            assert np.all(samples[-2000:] == 0)
            prefix = "acoustic_guitar" if t == 3 else "piano"
            exports[f"{prefix}_{'single' if segment == 0 else 'arpeggio'}.wav"] = samples
        single = tracks[t, 0]
        steady = single[4096:12288].astype(float)
        spectrum = np.abs(np.fft.rfft((steady - steady.mean()) * np.hanning(8192)))
        freq = np.fft.rfftfreq(8192, 1 / RATE)
        band = np.abs(freq - 440) < 15
        peak = freq[band][np.argmax(spectrum[band])]
        assert abs(peak - 440) < RATE / 8192
        spectra[t] = spectrum / np.linalg.norm(spectrum)
        attack = single[256:4352].astype(float)
        attack_spectrum = np.abs(np.fft.rfft(
            (attack - attack.mean()) * np.hanning(len(attack))))
        attack_freq = np.fft.rfftfreq(len(attack), 1 / RATE)
        harmonics = np.asarray([
            attack_spectrum[np.abs(attack_freq - 440 * harmonic) < 20].max()
            for harmonic in range(1, 9)])
        attack_harmonics[t] = float(np.linalg.norm(harmonics[2:]) / harmonics[0])
        axes[row, 0].plot(np.arange(len(single)) / RATE, single / 8388608)
        axes[row, 0].set(title=name, xlabel="Seconds", ylabel="PCM / full scale")
        axes[row, 1].plot(freq, 20 * np.log10(np.maximum(spectrum / spectrum.max(), 1e-6)))
        axes[row, 1].set(xlim=(0, 5000), ylim=(-90, 5), xlabel="Hz", ylabel="Relative dB")
        print(f"PASS: {name} A4 peak {peak:.2f} Hz")
    distance = np.linalg.norm(spectra[0] - spectra[3])
    assert distance > 0.45, f"steady spectra too close to piano: {distance:.3f}"
    assert attack_harmonics[3] > attack_harmonics[0] * 2.5, (
        "guitar attack lost upper partials", attack_harmonics)
    guitar = tracks[3, 0]
    rms = lambda a: np.sqrt(np.mean(a.astype(float) ** 2))
    assert rms(guitar[24000:32000]) < rms(guitar[2000:10000]) * 0.5
    for name, samples in exports.items():
        wav(OUT / name, samples)
    gap = np.zeros(12000, dtype=np.int32)
    wav(OUT / "piano_acoustic_guitar_compare.wav", np.concatenate(
        [np.concatenate((tracks[t, 1], gap)) for t in (0, 3)]))
    # Attenuate only: compare colour without a loudness advantage or clipping.
    levels = {t: rms(tracks[t, 0][512:24000]) for t in (0, 3)}
    target_level = min(levels.values())
    matched = {t: np.rint(tracks[t, 0] * (target_level / levels[t])).astype(np.int32)
               for t in (0, 3)}
    wav(OUT / "piano_acoustic_guitar_single_compare.wav", np.concatenate(
        [np.concatenate((matched[t], gap)) for t in (0, 3)]))
    fig.savefig(OUT / "acoustic_guitar_waveform_spectrum.png", dpi=150)
    plt.close(fig)
    print(f"PASS: gain-normalized spectral distance {distance:.3f}; guitar decays naturally")
    print(f"PASS: attack upper-partial ratios piano/guitar {attack_harmonics}")
    print("Exported: RMS-matched single-note comparison (piano first, guitar second)")


if __name__ == "__main__":
    main()

import csv
import wave
from pathlib import Path

import numpy as np

def write_wav(path, samples):
    with wave.open(str(path), "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(3)
        stream.setframerate(48000)
        stream.writeframes(b"".join(int(v).to_bytes(4, "little", signed=True)[:3]
                                   for v in samples))

OUT = Path(__file__).parent / "build" / "iverilog" / "waveforms"


def load(name, expected_length):
    with (OUT / f"{name}.csv").open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    samples = np.array([int(row["audio"]) for row in rows], dtype=np.int32)
    indices = np.array([int(row["sample_index"]) for row in rows])
    active = np.array([int(row["active"]) for row in rows])
    assert len(samples) == expected_length
    assert np.array_equal(indices, np.arange(len(samples)))
    assert 0 < np.max(np.abs(samples)) < 8388607
    assert np.all(samples[-4000:] == 0)
    write_wav(OUT / f"{name}.wav", samples)
    return samples, active


def main():
    single, _ = load("bianzhong_single", 201600)
    segment = single[2048:18432].astype(float)
    freq = np.fft.rfftfreq(len(segment), 1/48000)
    spec = np.abs(np.fft.rfft((segment-segment.mean()) * np.hanning(len(segment))))
    f0 = 440 * 2 ** ((60-69)/12)
    for ratio in (1, 6103/4096, 8356/4096, 10977/4096):
        band = np.abs(freq-f0*ratio) < 12
        peak = freq[band][np.argmax(spec[band])]
        assert abs(peak-f0*ratio) < 48000/len(segment)
        assert np.max(spec[band]) > np.max(spec)*0.02
    early = np.sqrt(np.mean(single[4000:24000].astype(float)**2))
    late = np.sqrt(np.mean(single[110000:130000].astype(float)**2))
    assert 0 < late < early*0.65, (early, late)
    melody, active = load("bianzhong_ode", 556800)
    assert np.count_nonzero(active>1) > 1000
    print(f"PASS: inharmonic modes, decay, overlap, no PCM rail hits, silent tail; "
          f"single {len(single)/48000:.2f}s, melody {len(melody)/48000:.2f}s")
    print(f"Exported: {OUT / 'bianzhong_ode.wav'}")
    print(f"Exported: {OUT / 'bianzhong_single.wav'}")


if __name__ == "__main__":
    main()

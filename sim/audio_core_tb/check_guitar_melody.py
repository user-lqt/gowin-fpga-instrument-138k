from pathlib import Path
import csv
import wave
import numpy as np

ROOT = Path(__file__).parent
OUT = ROOT / "build" / "iverilog" / "waveforms"
TRACE = OUT / "guitar_twinkle.csv"

def write_wav(path, samples):
    samples = np.clip(samples, -8388608, 8388607).astype(np.int32)
    raw = b"".join(int(v).to_bytes(4, "little", signed=True)[:3] for v in samples)
    with wave.open(str(path), "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(3)
        stream.setframerate(48000)
        stream.writeframes(raw)

def main():
    with TRACE.open(newline="") as stream:
        samples = np.asarray([int(row["audio"]) for row in csv.DictReader(stream)],
                             dtype=np.int32)
    if len(samples) != 14 * 34286:
        raise AssertionError(f"unexpected guitar melody length: {len(samples)}")
    if np.max(np.abs(samples)) >= 8388607 or np.max(np.abs(samples)) == 0:
        raise AssertionError("invalid or clipped guitar melody PCM")
    path = OUT / "guitar_twinkle.wav"
    write_wav(path, samples)
    print(f"PASS: {len(samples)} samples, {len(samples) / 48000:.2f}s")
    print(f"Exported: {path}")

if __name__ == "__main__":
    main()

from pathlib import Path
import csv
import wave
import numpy as np

ROOT = Path(__file__).parent
OUT = ROOT / "build" / "iverilog" / "waveforms"
TRACE = OUT / "piano_upright_twinkle.csv"

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
    if len(samples) != 14 * 34286 + 5000:
        raise AssertionError(f"unexpected melody length: {len(samples)}")
    if np.max(np.abs(samples)) >= 8388607 or np.max(np.abs(samples)) == 0:
        raise AssertionError("invalid or clipped melody PCM")
    if np.any(samples[-200:]):
        raise AssertionError("melody release did not reach silence")
    with (OUT / "piano_upright_register.csv").open(newline="") as stream:
        register = np.asarray([int(row["audio"]) for row in csv.DictReader(stream)],
                              dtype=np.int32)
    if len(register) != 6 * 25200:
        raise AssertionError("incomplete register capture")
    if np.max(np.abs(register)) >= 8388607:
        raise AssertionError("register PCM clipping")
    energies = []
    for i, segment in enumerate(register.reshape(6, 25200)):
        if np.any(segment[-200:]):
            raise AssertionError("register release did not reach silence")
        early = np.sqrt(np.mean(segment[2400:4800].astype(float) ** 2))
        late = np.sqrt(np.mean(segment[14400:16800].astype(float) ** 2))
        if not early > late > 0:
            raise AssertionError(f"register {i}: missing decay")
        energies.append(early)
        write_wav(OUT / f"piano_upright_note_{60 + (i // 2) * 9}_{'soft' if i % 2 == 0 else 'hard'}.wav",
                  segment)
    if any(energies[i + 1] <= energies[i] for i in (0, 2, 4)):
        raise AssertionError("hard strike must be louder than soft strike")
    path = OUT / "piano_upright_twinkle.wav"
    write_wav(path, samples)
    print(f"PASS: {len(samples)} samples, {len(samples) / 48000:.2f}s")
    print(f"Exported: {path}")
    print("PASS: three registers, soft/hard dynamics, decay, silent release tails")

if __name__ == "__main__":
    main()

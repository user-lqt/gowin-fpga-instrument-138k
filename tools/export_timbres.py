"""Convert samples emitted by tb_timbres into mono 48 kHz WAV files."""
from pathlib import Path
import struct
import wave

root = Path(__file__).resolve().parents[1]
source = root / "sim/audio_core_tb/build/iverilog/waveforms"
target = root / "output/timbres"
target.mkdir(parents=True, exist_ok=True)
for name in ("sine", "triangle", "saw"):
    samples = [int(line) for line in (source / f"timbre_{name}.txt").read_text().splitlines()]
    if len(samples) != 48000 or any(not -32768 <= s <= 32767 for s in samples):
        raise ValueError(f"invalid {name} samples")
    with wave.open(str(target / f"{name}_c4.wav"), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(48000)
        out.writeframes(struct.pack("<" + "h" * len(samples), *samples))
    print(target / f"{name}_c4.wav")

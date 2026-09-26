"""Check the sampled A2 trace emitted by tb_audio_core_a2."""

from pathlib import Path

import numpy as np


TRACE = Path(__file__).parent / "build" / "iverilog" / "waveforms" / "a2_samples.csv"
data = np.genfromtxt(TRACE, delimiter=",", names=True, dtype=np.int64)


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print(f"PASS: {message}")


chord = data[data["scenario"] == 2]
steady = chord[-4096:]
expected_notes = (60, 64, 67, 69)
for index, note in enumerate(expected_notes):
    phase = steady[f"phase{index}"]
    steps = np.mod(np.diff(phase), 2**32)
    expected_step = round(440 * 2 ** ((note - 69) / 12) * 2**32 / 48000)
    check(np.all(steady[f"note{index}"] == note), f"voice {index} note {note}")
    check(np.all(steps == expected_step), f"voice {index} independent phase increment")
    check(np.all(steady[f"stage{index}"] == 3), f"voice {index} holds sustain")

freq = np.fft.rfftfreq(len(steady), 1 / 48000)
power = np.abs(np.fft.rfft(steady["audio"] * np.hanning(len(steady))))
for note in expected_notes:
    target = 440 * 2 ** ((note - 69) / 12)
    bins = np.abs(freq - target) <= 12
    local_peak = freq[bins][np.argmax(power[bins])]
    check(abs(local_peak - target) < 6, f"note {note} spectrum peak {local_peak:.2f} Hz")

release_data = data[data["scenario"] == 5]
release = release_data["env1"][release_data["stage1"] == 4]
check(len(release) == 4800 and np.all(np.diff(release) <= 0),
      "normal release lasts 4800 samples and falls monotonically")
check(release[0] == 45875 and release[-1] > 0 and release_data["env1"][-1] == 0,
      "normal release ends at zero without a premature cut")
early_data = data[data["scenario"] == 7]
early = early_data["env0"][early_data["stage0"] == 4]
check(len(early) == 4800 and np.all(np.diff(early) <= 0),
      "early release lasts 4800 samples and falls monotonically")
check(0 < early[0] < 4800 and early[-1] > 0 and
      np.any(early_data["stage0"] == 0), "low-level release ends at zero")
check(np.max(np.abs(steady["audio"])) < 8388608, "default chord stays in signed 24-bit range")
print(f"A2 waveform PASS: {len(data)} valid samples analyzed")

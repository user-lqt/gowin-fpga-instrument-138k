# Member A Audio Workspace

## Source of Truth

- `../../rtl/audio_core/`: the only editable audio RTL.
- `tb_audio_core.v`: A1 top-level regression, including FIFO collisions and overflow mute.
- `tb_adsr.v`, `tb_mixer.v`, `tb_voice_allocator.v`, `tb_voice.v`: A2 module tests.
- `tb_audio_core_a2.v`: integrated four-voice test and sample trace.
- `audio_core_sim/audio_core_sim.gprj`: existing Gowin project; paths still reference the canonical RTL.
- `gen_tables.py`: table generator. Do not regenerate tables as part of directory cleanup.

A3 is the default configuration of `audio_core.v`, with 32 independent voices,
three FPGA-generated timbres, ADSR, voice stealing, and a serial saturating
mixer. A2 compatibility is selected by `VOICE_COUNT=4`, `ENABLE_STEAL=0`,
`ENABLE_TIMBRES=0`, and `EVENT_DEPTH=16`; A1 uses `ENABLE_POLYPHONY=0`.
The external ports are unchanged. A3 has not been verified by Gowin synthesis,
timing analysis, or board testing in this work.
`tb_audio_core_a3.v` checks the A3 contract with a 256-clock sample period,
including 32 active voices, deterministic stealing, timbre latching, velocity,
volume smoothing, saturation, reset recovery, and continuous valid output.
Its instance overrides attack/decay/release to 8/16/64 samples. With A3 timbres
enabled, attack and decay use instrument-specific settings, so only the release
override changes the envelope timing: 64 samples in this test versus the
production default of 4800. A3 attack limits are 96/240/1200 samples for
piano/organ/trumpet; decay limits are 32768/1/3932 samples, respectively.
The short 128-sample captures establish nonzero, different PCM outputs, not
32-note spectral resolution, realistic instrument identity, or listening approval.
Full-duration A3 release, long spectral captures and listening approval remain
pending. The separate A2 regression tests the default 4800-sample release.
`voice_allocator` expects a sample-tick-aligned dequeue from the upstream FIFO,
not raw asynchronous-to-tick event pulses.
In A2 compatibility mode, four occupied voices reject a fifth note rather than
stealing an active or releasing voice. A3 steals a released voice first, then
selects the lowest envelope level, then greatest age, then lowest slot index.
A high volume may clip, indicated by `overload_flag`.
The exact-duration release computes a constant quotient and remainder on
NOTE_OFF; member C should inspect the synthesized divider cost and timing.

## Local Regression

From the repository root:

```powershell
.\sim\audio_core_tb\run.ps1 -Stage A2
.\sim\audio_core_tb\run.ps1 -Stage A3
.\sim\audio_core_tb\run.ps1 -Stage A1
.\sim\audio_core_tb\run.ps1 -Stage All
```

Generated executables and waveforms go to ignored `build/iverilog/`. A3 writes
`waveforms/a3_samples.csv`; A2 runs the
waveform checker after the five RTL tests. It analyzes `waveforms/a2_samples.csv`
for four phase increments, chord spectral peaks, independent sustain, release
curves and sample range. `waveforms/tb_audio_core_a2.vcd` contains the detailed
signal transitions for inspection.

## Independent Questa Verification

In Questa Transcript, use the absolute path to `questa.do`, followed by the
desired testbench name:

```tcl
do C:/Users/lenovo/gowin-fpga-instrument-138k/sim/audio_core_tb/questa.do tb_adsr
```

Other targets: `tb_mixer`, `tb_voice_allocator`, `tb_voice`, `tb_audio_core`,
`tb_audio_core_a2`.
The script recompiles canonical sources and uses ignored `build/questa/`.
Questa verification is paused for the next stage. Icarus PASS is not Questa
PASS. Gowin synthesis, timing and board verification belong to member C.

## Preserved History

`local_archive/legacy_sim/` contains the old A1/A2 Questa
projects, compiled libraries, and waveforms. They were moved, not deleted.
The old projects use absolute paths to the same canonical sources; their stale
compiled `*_debug` units must not be treated as current verification results.
The archive is local-only and is not a source or build dependency.

Git branch `a2-audio-local` points to the older A1 base, not a separate working
directory. The original A2 stash remains a historical backup. Do not apply it
again over the repaired A2 working files.

# Member A Audio Workspace

## Source of Truth

- `../../rtl/audio_core/`: the only editable audio RTL.
- `tb_audio_core.v`: A1 top-level regression, including FIFO collisions and overflow mute.
- `tb_adsr.v`, `tb_mixer.v`, `tb_voice_allocator.v`, `tb_voice.v`: A2 module tests.
- `tb_audio_core_a2.v`: integrated four-voice test and sample trace.
- `audio_core_sim/audio_core_sim.gprj`: existing Gowin project; paths still reference the canonical RTL.
- `gen_tables.py`: table generator. Do not regenerate tables as part of directory cleanup.

A2 is the default configuration of `audio_core.v`, with four independent sine
voices, ADSR, and a signed saturating mixer. Fixed sum/4 headroom is separate
from the full-range 0xffff default user volume.
The original A1 behavior is selected by `ENABLE_POLYPHONY=0` in its regression.
The external interface is unchanged. Full-system simulation uses the actual
keyboard/encoder/audio/serializer RTL; physical acceptance remains pending.
`voice_allocator` expects a sample-tick-aligned dequeue from the upstream FIFO,
not raw asynchronous-to-tick event pulses.
Four occupied voices reject a fifth note rather than stealing an active or
releasing voice. Four valid voices cannot clip at maximum user volume;
`overload_flag` remains available for fault diagnostics.
The exact-duration release computes a constant quotient and remainder on
NOTE_OFF; member C should inspect the synthesized divider cost and timing.

## Local Regression

From the repository root:

```powershell
.\sim\audio_core_tb\run.ps1 -Stage A2
.\sim\audio_core_tb\run.ps1 -Stage A1
.\sim\audio_core_tb\run.ps1 -Stage All
```

Generated executables and waveforms go to ignored `build/iverilog/`. A2 runs the
waveform checker after the five RTL tests. It analyzes `waveforms/a2_samples.csv`
for four phase increments, chord spectral peaks, independent sustain, release
curves and sample range. `waveforms/tb_audio_core_a2.vcd` contains the detailed
signal transitions for inspection.

## ModelSim Verification

On this machine, ModelSim 10.1d regression is available through
`tools/verify_stage2.ps1` (all A/B/C tests) or `run_a2.ps1` (A tests).
Gowin synthesis, timing and physical verification belong to member C.

## Preserved History

`local_archive/legacy_sim/` contains the old A1/A2 Questa
projects, compiled libraries, and waveforms. They were moved, not deleted.
The old projects use absolute paths to the same canonical sources; their stale
compiled `*_debug` units must not be treated as current verification results.
The archive is local-only and is not a source or build dependency.

Git branch `a2-audio-local` points to the older A1 base, not a separate working
directory. The original A2 stash remains a historical backup. Do not apply it
again over the repaired A2 working files.

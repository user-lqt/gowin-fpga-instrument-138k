# Member A Audio Workspace

## Source of Truth

- `../../rtl/audio_core/`: the only editable audio RTL.
- `tb_audio_core.v`: A1 top-level regression, including FIFO collisions and overflow mute.
- `tb_adsr.v`, `tb_mixer.v`, `tb_voice_allocator.v`, `tb_voice.v`: A2 module tests.
- `tb_audio_core_a2.v`: integrated four-voice test and sample trace.
- `audio_core_sim/audio_core_sim.gprj`: existing Gowin project; paths still reference the canonical RTL.
- `gen_tables.py`: table generator. Do not regenerate tables as part of directory cleanup.

A2 is the default configuration of `audio_core.v`, with four independent sine
voices, ADSR, a signed saturating mixer, and 0x3fff default volume headroom.
The original A1 behavior is selected by `ENABLE_POLYPHONY=0` in its regression.
The external interface is unchanged; A2 has not been tested in the full system
or on the board.
`voice_allocator` expects a sample-tick-aligned dequeue from the upstream FIFO,
not raw asynchronous-to-tick event pulses.
Four occupied voices reject a fifth note rather than stealing an active or
releasing voice. A high volume may clip, indicated by `overload_flag`.
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

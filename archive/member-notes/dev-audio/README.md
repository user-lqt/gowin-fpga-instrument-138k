# Member A Audio Baseline / Member B Velocity Work

## Source and Ownership

Use the existing `dev-audio` branch and `rtl/audio_core/` directory.
There is no separate handoff folder. This delivery is the 32-voice baseline,
not the experimental 64-voice core or the ignored private Gowin system.

Member B owns both key velocity detection and velocity-dependent loudness,
harmonics and timbre changes. Member A will port B's changes to the banked
64-voice core and run integration regressions. That port is not automatic.
Member C owns the system project, synthesis, timing and board verification.
No B/C source directories, pin constraints or common event headers are changed.

Keep the common event interface unchanged: NOTE_ON carries `note_id` and
8-bit `velocity` (normal range 1..127); NOTE_OFF releases the note.
Velocity should alter amplitude and spectral proportions, not the note's
fundamental frequency or note mapping.

Useful starting points for B:

- `rtl/audio_core/voice.v`: latched velocity, gain and piano transient.
- `rtl/audio_core/oscillator.v`: piano partial weights and brightness.
- `rtl/audio_core/plucked_string.v`: guitar excitation and damping;
  the baseline damping currently switches at velocity >90.
- `rtl/audio_core/guitar_body_tone_bank.v`: shared guitar body processing.
- `rtl/audio_core/bianzhong_ram_bank.v`: eight-mode bell processing;
  the baseline scales loudness but does not vary modal weights with velocity.
- `rtl/audio_core/audio_core.v`: scheduling, event queues and shared gains.
- `sim/audio_core_tb/`: testbenches and reproducible regression commands.

B should supply changed modules, the velocity mapping/formulas and soft,
medium and hard strike tests for all three instruments at the same note.
Keep shared scheduling and sample deadlines intact. Changes to arithmetic
widths or state storage need corresponding 64-voice migration review.

## Production Configuration

Default `audio_core` uses 32 independent voices and shared arithmetic.
No audition-only defines are needed.

| PARAM_INSTRUMENT | Sound |
| --- | --- |
| 0 | Upright-style acoustic piano |
| 1 | Acoustic-style guitar |
| 2 | Eight-mode inharmonic bianzhong |
| 3 | Compatibility alias of guitar, not a fourth sound |
| >3 | Falls back to piano |

Held voices retain their latched instrument when the global selection changes.
All audio is computed sample-by-sample by HDL; reference recordings provide
offline scalar model parameters, not embedded PCM playback.
These are instrument models, not sample-library clones.

The pacing contract is 12.288 MHz / 48 kHz = 256 clocks per sample.
Default 32-voice PCM valid latency is 109 clocks after sample_tick.
Shared velocity gain starts at clock 70; envelope gain occupies clocks 74..77.
Do not substitute the obsolete 50-clock timing.
Default volume is 0x07ff with a 64-unit-per-sample ramp.
Default NOTE_OFF release is 4800 samples.

The guitar uses a fractional-delay feedback string and shared body banks.
The bell uses eight inharmonic modes and shared RAM banks; it is not the
superseded fixed additive bell. Include ALL `.v` files in `rtl/audio_core/`
when integrating, including the new bank, pitch and note-period modules.
Keep `rtl/common/` on the Verilog include path.

`ENABLE_EXPRESSION=0` is the default routed-baseline configuration.
Setting it to 1 enables pitch bend, glide and vibrato processing.
Expression-enabled simulation is separate evidence from hardware timing
approval; it does not imply a newly routed or board-verified system.

## Regression Commands

Run from the repository root with Icarus Verilog on PATH and Python/numpy:

```powershell
.\sim\audio_core_tb\run.ps1 -Stage All
.\sim\audio_core_tb\run.ps1 -Stage Expression
.\sim\audio_core_tb\run.ps1 -Stage Velocity
.\sim\audio_core_tb\run.ps1 -Stage A3Long
.\sim\audio_core_tb\run.ps1 -Stage Piano
.\sim\audio_core_tb\run.ps1 -Stage GuitarMelody
```

`All` runs A1, five A2 tests, A3 short regression, hardware cadence and velocity.
`Hardware` selects just the 32-voice, 256-clock cadence test.
`Expression` runs that fixture with bend, glide and vibrato enabled together.
`Velocity` captures soft, medium and hard strikes at one note for all three
instruments, checks pitch invariance and records a CSV baseline for B.
A1 uses the explicit legacy monophonic path.
A2 uses four voices with timbres/stealing disabled and event depth 16.
A3 covers 32 independent phases, stealing, held-instrument latching, velocity,
volume smoothing, saturation, queues, reset and sample cadence.

`A3Long` checks the mixer reference, 4096 full-load frames and the default
4800-sample release on every slot, then captures single-note timbres.
Single-voice audition/melody tests use 75-clock valid latency at 256 clocks
per sample; the four-voice guitar fixture uses 81-clock latency.
These tests generate PCM interpreted at 48 kHz; the testbench clock itself
is accelerated. Separate per-voice traces distinguish voices from harmonics.

Outputs are ignored under `sim/audio_core_tb/build/iverilog/waveforms/`.
Long captures and audition renders are optional and can take substantial time.
Different PCM alone is not proof of convincing instrument identity.
Tests do not prove Gowin resource fit, board sound or end-to-end latency.

Delivery verification: A1 passed 46 checks; A2 unit checks passed
22 ADSR / 11 mixer / 19 allocator / 12 voice checks; A2 integration passed
41 scenarios with 27496 PCM frames, including offline waveform analysis.
The new velocity baseline passed 1197 frames for three instruments.
Long/audition/guitar/melody fixtures were compiled, not fully rerun.
Duplicate A3/hardware runs were stopped before completion; they are not
reported as fresh passes. The delivered RTL matches the accepted private
32-voice candidate byte-for-byte, whose source-hash evidence audit passed
(A3, full-load cadence, combined expression and system integration).

`questa.do` recompiles canonical sources in ignored `build/questa/`; A1/A2,
A3 and hardware-cadence targets are available. Independent Questa verification
remains paused, and no new Questa results are claimed.
`audio_core_sim/audio_core_sim.gprj` is the existing audio-only project,
not C's system project. Private system projects remain local and ignored.

## Integration Boundaries

This source baseline comes from the accepted local 32-voice shared-tone
candidate. Historical private-system synthesis/route evidence is not a fresh
verification of the public B/C integrated system.
The 24-key/EC11/DAC/LCD board path still requires team integration and
member C's hardware acceptance. String tuning over the entire MIDI range,
retrigger/steal clicks and velocity timbre realism require listening checks.
Original reference FLAC files and generated audition audio are not committed.

# Three-instrument strike dynamics

## Baselines and integration boundary

The member-A baseline is `dev-audio/6035c11`. Remote inspection on 2026-10-07
found C's root system at `integration/c-stage3/841892c` and B's separate
project at `integration/b-stage3-fsr/732163d`, under
`standalone/b-stage3-two-timbres/`. These are different audio configurations.
B's standalone velocity changes are not automatically C's root audio changes.

B's current standalone `keyboard_24_dual.travel_velocity` uses calibrated
per-key thresholds but emits only 127 below the threshold and 16 otherwise.
The audio curves support intermediate values, but the physical keyboard
will still provide only two dynamics unless B implements a measured
continuous travel-time curve. One threshold per key is insufficient evidence
for choosing reliable soft/hard endpoints of such a curve; contact geometry,
scan period and actual measured travel times must be checked on the prototype.

This change updates member-A's public 32-voice HDL and tests. It does not
change B's contact timing, velocity calibration, encoders, or C's project,
constraints, ADC, display, DAC frame buffer, or board validation.
The private 64-voice snapshot has NOT received these changes.

## Behavior

Instrument IDs remain piano 0, guitar 1 (alias 3), and bianzhong 2.
Velocity is saturated to 127. Pitch control and modal ratios do not depend
on velocity; dynamics changes excitation, gain, and spectral balance.

| Model | Soft strike | Hard strike | Key release |
| --- | --- | --- | --- |
| Piano | Lower nonlinear gain, weaker upper partials, 2.5 ms attack | Higher gain and upper partials, 1.25 ms attack | Existing 100 ms damping |
| Guitar | Weaker broadband excitation and pick transient | Stronger broadband excitation and pick transient | Existing 100 ms damping |
| Bianzhong | Lower gain, weak upper modes, 1 ms attack | Higher gain and upper modes, 0.5 ms attack | No damper; modes continue decaying |

The bell's envelope starts a bounded lifetime after attack: by default
288000 samples (6 seconds at 48 kHz), with a 32768-sample final fade.
NOTE_OFF still clears allocator key ownership. The voice remains active
for its natural tail and can be stolen under voice pressure. Holding a key
does not sustain the bell indefinitely. Retriggering restarts the strike.

B's standalone soft attacks were 40 ms for piano and 20 ms for bell.
That is an excessively slow rise for this struck-instrument model.
All instruments entering a 100 ms NOTE_OFF release also cut bell resonance.
This revision uses short strikes and an instrument-specific release policy.
These are perceptual synthesis models, not exact reconstructions of recordings.
Physical keyboard calibration and listening approval remain necessary.

## Resource findings

C's `docs/FSR_VIBRATO_INTEGRATION.md` records:

| Same documented synthesis comparison | Three instruments | Without guitar |
| --- | --- | --- |
| Logic | 131151 / 138240 | 76333 / 138240 |
| Registers | 42189 | 24922 |
| BSRAM | 84 / 340 | 20 / 340 |

The three-instrument build fits the reported logic count at about 95% but
failed routing with 6900 unrouted nets. Capacity, congestion, and timing are
different checks. This record is not proof that every failed build exceeded
138240; the exact failing report must be identified for that claim.
The difference is 54818 logic units in this particular comparison.
Do not mix B's standalone resource table with C's system measurements.

Each of 32 guitar voices has its own 2048 x 16 delay line, fractional
interpolation, excitation logic, transient arithmetic, and string state.
That is 1048576 raw delay bits before inference, plus addressing, muxes,
arithmetic and shared body filters. A menu selecting piano does not remove
the other instruments' generated hardware.
DSP/BSRAM totals below capacity do not rule out LUT or routing pressure.
Initial planning estimates of ample resources are not synthesis evidence.

This revision:

- Reuses the existing scheduled voice gain multiplier.
- Uses shift/add bell mode levels without a new multiplier per mode.
- Time-multiplexes the existing guitar transient multiplier between delay
  filling and playback; guitar velocity excitation is continuous.
- Narrows the guitar excitation constant divider from 17 to 12 bits before
  dividing by 3, with exhaustive RTL proof of exact displacement results.
- Preserves C's `ENABLE_GUITAR` compile-time parameter; default 1 supports
  all instruments, 0 excludes guitar hardware and maps selections to 0/2.

No new synthesis or PNR was run. These changes do not establish a new LUT
count or prove that all three instruments now route successfully.
The subsequent local string-arithmetic optimization and generic gate
comparison are described separately in `AUDIO_RESOURCES.md`; neither is
new Gowin evidence.
Restoring guitar on the board requires C to enable it and verify a new
full system build. Larger savings require shared/interleaved guitar state
and arithmetic, controlled RAM inference, and hierarchical synthesis
measurements. Do not shorten delay lines blindly: that changes low-note
range and pitch/expression behavior.

## Reproduction

```powershell
.\sim\audio_core_tb\run.ps1 -Stage All
.\sim\audio_core_tb\run.ps1 -Stage Dynamics
.\sim\audio_core_tb\run.ps1 -Stage VelocityEndpoints
.\sim\audio_core_tb\run.ps1 -Stage Expression
```

`All`: legacy A1/A2, 32-voice A3, real 256-clock/sample budget, short
three-instrument velocity test.
`Dynamics`: all 65536 displacement phases, saturated monotonic gain curve,
nine long PCM captures, RMS and gain-normalized spectral differences,
one second of bit-exact early-tap/held-bell PCM, full six-second envelope
termination and retrigger. Its one-voice diagnostic runs at 96 clocks per
sample; it is not a substitute for the 32-voice 256-clock hardware fixture.
`VelocityEndpoints` repeats the short test at B's actual 16/127 endpoints
(with 80 as an intermediate audio-model probe).

The hardware fixture uses a deliberately shortened 512-sample bell lifetime
(2048 samples with expression enabled)
to test 32-voice tail allocation without simulating six seconds for every
lane. The separate envelope test checks the unmodified default lifetime.
`A3Long` audition expectations were updated for the bell's natural tail.
Questa independent verification and Gowin synthesis/PNR/board listening
are not covered by Icarus results.

Generated CSV, WAV, PNG, metrics and logs stay in the ignored
`sim/audio_core_tb/build/iverilog/` directory.

## C handoff

Merge these seven HDL files together, not only `adsr.v`:
`audio_core.v`, `voice.v`, `adsr.v`, `oscillator.v`, `plucked_string.v`,
`bianzhong.v`, `bianzhong_ram_bank.v`.
The strike helper modules are inside `voice.v`; no new project file is needed.
The bell velocity port must be connected in both private and shared paths.
Keep C's system integration and `ENABLE_GUITAR` selection intact.
B's independent project requires a deliberate merge; replacing its entire
folder would discard its separate UI and integration work.
Any downstream test asserting bell silence 100 ms after NOTE_OFF must be
changed to check natural ringing followed by bounded reclamation.

## Validation Results

The final dynamics capture contains 147456 samples in nine strike tracks
and 48000 samples of paired short-tap/held-bell output. Every paired bell
sample is identical. The full default envelope lifetime and retrigger pass.
The guitar divider is bit-exact for all 65536 phase positions.
The FFT bin containing A4 is 441.964 Hz for all nine tracks (bin resolution
6.696 Hz); velocity does not shift the identified fundamental bin.

| Instrument | Soft / medium / hard RMS | Normalized soft-to-hard spectral distance |
| --- | --- | --- |
| Piano | 8234 / 33373 / 61191 | 0.1011 |
| Guitar | 1529 / 3978 / 6369 | 0.5795 |
| Bianzhong | 14315 / 37763 / 59787 | 0.2267 |

These RMS values use the same raw PCM scaling and analysis window, not
separately normalized listening tracks. Spectral differences remove gain,
so they demonstrate excitation/colour changes, not merely louder PCM.
The 16/80/127 endpoint fixture also passes energy ordering and fixed pitch
control for all three instruments.

The exploratory `All` run was stopped during A3 after further guitar edits;
its partial log is NOT a final full-suite pass. A1/A2 completed in that run,
and final-source legacy/A3/audition/expression fixtures compile. The separate
`Hardware` run at the dynamics-revision boundary passed all three instruments with 32 distinct
voices, released-key bell tails, bounded voice reclamation and silent
completion: 1190 valid frames, PCM latency 109 clocks, period 256 clocks.
This predates the subsequent string-arithmetic refactor; that refactor's
final-source coverage is recorded in `AUDIO_RESOURCES.md`.
The extended `A3Long` and expression runtime suites were not rerun to
completion in this task; their compile checks are not runtime evidence.

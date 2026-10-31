# Guitar arithmetic resource reduction

## Scope

This revision keeps 32 voices, all three instruments, 2048 x 16 delay
memories, velocity response, and pitch/expression controls. No B/C project,
constraint, keyboard, display or DAC file is changed.
It follows the dynamics corrections in `AUDIO_DYNAMICS.md`.
The private 64-voice candidate has not been updated.

The resource revision includes the scheduled guitar arithmetic change in
`rtl/audio_core/plucked_string.v` and the RAM-backed guitar body filter in
`rtl/audio_core/guitar_body_ram_bank.v`. The local Gowin project references
the RAM body module and `audio_core` selects it by default with `RAM_BODY=1`.
The default `SHARE_ARITHMETIC=1` selects the optimized path.
`SHARE_ARITHMETIC=0` selects the immediately preceding dynamics model for
differential tests, not an earlier GitHub version of the guitar sound.
The parameter does not change the audio-core interface or instrument IDs.

## Changes

- Schedule interpolation at the sample edge and prepare playback pick
  products on idle clocks using one full-width multiplier.
- Preserve the first playback sample even when filling ends immediately
  before a sample edge. Its still-undecayed gain has nine zero low bits;
  a separate narrow 17 x 8 product covers this boundary exactly.
- Share the filling displacement and playback pick-decay division by 3.
- Implement division by 3/5 with bounded 2/3-bit remainders and 12 quotient
  steps rather than unrestricted-width division operators.
- Keep the RAM ports, initialization rate, loop feedback, fractional delay,
  output saturation and sample-boundary state updates unchanged.

The full-width multiplier count in the 32 string modules falls from 64
to 32, but there are also 32 narrow first-playback products. Do not describe
that as removing 32 total multipliers or as a measured DSP-block reduction.
The optimized path needs an idle clock between playback sample pulses.
The supported audio-core schedules provide 96 or 256 clocks per sample;
back-to-back high sample pulses are not an integration mode.

## Guitar body filter comparison

The formal 16-lane body modules were synthesized independently with Gowin
V1.9.12 for `GW5AST-LV138PG484AC1/I0`. This is a module comparison, not a
full-system synthesis or place-and-route result.

| 16-lane module | LUT | ALU | Registers | BSRAM | MULTALU27X18 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `guitar_body_tone_bank` | 5602 | 274 | 3929 | 0 | 1 |
| `guitar_body_ram_bank` | 1856 | 274 | 942 | 6 | 1 |

The RAM implementation removes 3746 LUTs (66.88%) and 2987 registers
(76.02%) in this isolated module, while consuming six BSRAM blocks. The
formal measurement is reproducible with:

```powershell
powershell -ExecutionPolicy Bypass -File .\sim\audio_core_tb\measure_body_gowin.ps1
```

## Generic resource comparison

Yosys 0.69, dynamic-pitch string, identical front end and optimization:

`proc; opt; memory -nomap; opt; flatten; techmap; opt; stat`

This preserves RAM as a memory cell and maps arithmetic to generic gates
without Gowin LUT packing or DSP/BSRAM technology mapping.

| One string module | Reference | Optimized |
| --- | --- | --- |
| AND / MUX / NOT / OR / XOR gates | 9527 | 7292 |
| Flip-flops | 247 | 264 |
| Delay memory bits | 32768 | 32768 |

Combinational gate count decreases by 23.46%. The comparison includes the
first-playback boundary fix. An earlier 32.02% experiment lacked that
boundary fix and is not a valid delivery result.
These are NOT Gowin logic-unit counts, an estimate of total-system savings,
or evidence that the three-instrument design routes. DSP inference, LUT
packing and interconnect can make the device result substantially different.

Reproduce with native Yosys or the local optional YoWASP installation:

```powershell
.\sim\audio_core_tb\measure_string_logic.ps1
.\sim\audio_core_tb\measure_string_logic.ps1 -Yosys C:\tools\yosys.exe
```

Optional local measurement tools were installed only under the ignored
`sim/audio_core_tb/build/resource_tools/`, not in the RTL or public project.
Logs and netlists are also under ignored `build/iverilog/`.

## Verification

```powershell
.\sim\audio_core_tb\run.ps1 -Stage StringShared
.\sim\audio_core_tb\run.ps1 -Stage GuitarHardware
.\sim\audio_core_tb\run.ps1 -Stage Hardware
.\sim\audio_core_tb\run.ps1 -Stage Expression
```

`BodyRam` passes 512 frames for 1/2/3/4/5/7/8/15/16 lanes, including reset,
sample-boundary retrigger cases, and exact tone/history equivalence against
the register reference. The filter completes within the 256-clock sample
budget.

`StringShared` passes every 12-bit numerator for division by 3 and by 5.
It compares reference and optimized fixed/dynamic strings over 6805 frames,
including minimum/maximum/clamped delay, velocity 0/1/16/80/127/255,
retrigger, disable/reenable, pitch changes, reset and the immediate
fill-to-playback boundary and complete pick-gain decay to zero.
PCM, DC, pick gain, fractional state and every
RAM write are checked on every clock.
The legacy 65536-phase displacement equivalence test also passes.

The preliminary all-instrument hardware run was stopped after the
additional boundary test revealed the first-playback issue. That run is
not final-source verification. A new final-source 32-voice guitar run
passed bend/glide/vibrato together with the 256-clock budget: 1058 valid
frames, PCM latency 109 clocks, period 256 clocks, 32 distinct notes,
unchanged allocation during expression, neutral pitch after disabling
vibrato, and successful release to silence. Its log is
`build/iverilog/hardware_string_shared_final.log`.
The all-instrument and full long-audition runtime suites were not rerun to
completion for this refactor; their compilation checks passed. The
strings' per-clock PCM equivalence is separate from whole-system
or board acceptance.

## C handoff

Merge the dynamics files first, then this string implementation.
Keep `ENABLE_GUITAR=0` as the verified-board fallback until a new
three-instrument build completes. To evaluate this revision, explicitly
build a separate configuration with `ENABLE_GUITAR=1`.
Compare same-configuration hierarchical logic, registers, BSRAM and DSP
before/after, especially the string and body-filter instances. Inspect
unrouted nets and final audio-clock slack; synthesis success is not enough.
This task does not run Gowin, Questa or board acceptance, and does not push.

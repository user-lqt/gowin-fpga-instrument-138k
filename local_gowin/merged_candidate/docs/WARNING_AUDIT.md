# Warning Audit

## Scope

The local merged project is `project/instrument_velocity_32_two_timbres`.
Changes do not suppress diagnostic messages or disable timing analysis.

## EX3791: expression truncation

- EC11 menu, song selection, effect and tempo arithmetic now use explicit
  destination-width constants. Existing range limits are retained.
- Uploaded-score and physical-key indices retain explicit low-bit selection;
  upload and event validation still reject out-of-range keys.
- Event/reply FIFO temporary counts retain explicit destination slices.
  Audio FIFO pointers use a parameter-sized last-slot constant and increment.
- Beat-phase arithmetic has an explicit extended sum and remainder.
- Guitar interpolation and output mixing retain the original signed wide
  computation followed by explicit low-bit selection. These selections preserve
  existing fixed-point wrap behavior, rather than introducing saturation.
- Guitar RAM addressing is explicitly modulo 2048.

These edits make the existing numeric boundaries explicit. They are not a
change to the accepted bell profile, dynamics, sample rate or voice count.

## NL0002: swept note lookup instances

The synthesis tool reports removal of the shared `note_to_fc` and
`note_to_period` instances during optimization. Do not force preservation of
these instance boundaries merely to remove a warning. The RTL connections to
the allocator remain in place; the tool may merge/integrate equivalent logic.
RTL audio comparison is a functional regression, not gate-level verification.

## CK3000: independent PLL clock relationship

The audio and pixel clocks come from separate PLLs. The synthesis report names
their automatically generated `*.default_gen_clk` clocks and cannot calculate
their relationship. Do not assert a fixed relative phase to silence this.

The project SDC already defines both PLL output clocks and separates the audio
and pixel groups with `set_clock_groups -asynchronous`. The status, feature and
spectrum buses use held-payload request/acknowledge bridges. Waveform and XY
images use acknowledged ping-pong storage.

`tb_display_cdc` checks all three status bridge widths (210, 49, 128) with
independent clocks, burst requests, changing payloads and common reset.
This checks digital protocol coherence only: RTL simulation cannot model
metastability or prove routed delays and synchronizer placement.

CK3000 is retained, not hidden. Post-route acceptance must still verify:

- Both named PLL clocks and their derived output clocks resolve in STA.
- The asynchronous exception is applied to the intended clock groups.
- Timing within each clock domain meets its own requirement.
- CDC synchronization and held-data settling are physically acceptable.
- LCD and I2S external output budgets are valid for the attached hardware.

Reference: installed Gowin SUG940-2.0.1E, section 5.2.5 (clock groups).
At the time of the original warning audit, the available routed report preceded
the latest synthesis. That older report did not establish timing closure for
the newer netlist. This audit does not claim hardware acceptance.

## PR1014: input clock uses a generic routing resource

The completed PnR log reports:

```text
Generic routing resource will be used to clock signal 'i_clk_in_d'
```

This is a physical clock-resource warning, not an audio-data-path warning.
The pin report confirms that `i_clk_in` is on V22, configured as `EMCCLK`,
and that `i_clk_in_d` is placed on the PRIMARY global clock network at PBR3.
The same report shows the audio and pixel PLL outputs on PRIMARY global
clock resources.

The warning cannot be safely "fixed" by adding a fabric register, changing
the PLL, or moving the pin: those changes would either add skew or break the
verified board clock pinout. The correct acceptance check is the routed STA
report and hardware PLL-lock test. The earlier PnR report completed at 12:44:25
on 2026-10-16 and had zero negative slack endpoints for `clk_audio`, `clk_pixel`,
`lcd_clock`, and `dac_bck`. It predates synthesis at 13:14:54 and must not be
used as signoff for that newer synthesis. A subsequent PnR completed at 17:59:46;
its captured reports are published under `reports/`. Successful bitstream
generation alone does not establish complete timing or hardware acceptance.

## Functional verification

- All 20 module tests and top-level structural compilation passed with
  `tools/verify_merged.ps1 -SkipAudio`.
- ModelSim `tools/check_optimization_audio.do` completed 2304 output samples,
  covering three timbres, 32 notes, velocities, bend, vibrato, glide and release.
- All six CSV columns matched `tmp/resource_optimization/baseline_audio.csv`
  exactly. The baseline is under the repository root, outside this local project.
- The test-only Icarus procedural-force limitation in `tb_controls_display`
  was removed by forcing literal values. Added checks cover FX endpoints,
  reverse song wrapping and tempo endpoints; the updated test passes.

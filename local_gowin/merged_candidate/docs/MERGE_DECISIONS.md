# Local Complete-System Merge

## Sources

- Screen/BLE/phone/PCM5102A: `origin/integration/b-current-20261015`,
  commit `75e652fa900900c3facd5a7f67c072cc5556ecec`.
- Joystick comparison: `origin/feature/c-joystick-bend-test-20261015`,
  commit `63ef83b38afce4d1a961b3f8b48716b63a921f48`.
- Audio and previous integration: local `merged_candidate`, preserved before
  overlay at repository-root `tmp/team_merge/local_before`.
- Downloaded snapshots and build logs: repository-root `tmp/team_merge`.

Only the changed non-audio source/support files from B were overlaid. Local
audio RTL was not replaced by B's two-timbre engine. B's historical two-timbre
project name is retained for compatibility, but the integrated top enables
piano=0, guitar=1 and bell=2, 32 voices, shared arithmetic and RAM body state.
Remote bitstreams were not copied over the local candidate.

## Joystick Decision

C's joystick and our local version have the same four-sample average,
inclusive deadzone, calibrated asymmetric endpoints and SPI-error return-to-zero
behavior. C retains the correct MAX_BEND parameter contract; our local width
cleanup had incorrectly hardcoded 8192/8191 in the optimized branch.

Keep C's behavior with the local bounded-width datapath, restore parameterized
coefficients and use C's original regression plus a non-default MAX_BEND=4096
full-range sweep. This is not a different musical response curve.

The complete test firmware from C is not used as the base: it has two timbres,
the older display and onboard PT8211 output. The merged base is B's newer
PCM5102A system with A's audio restored.

MCP3008 CH0=FSR, CH1=X pitch bend, CH2=Y sampled only. Y modulation events are
filtered so they cannot overwrite FSR. The control queue supports four sources.
CENTER_X/CENTER_Y default to 512; real hardware calibration is still required.

## Resource and Timing Work

- Preserve shared voice arithmetic, ADSR bank and guitar/bell RAM paths.
- Serial time-to-BCD formatter; no runtime multiply/divide for calibration.
- Replace selected frequency decimal divisions with a constant BCD ROM.
- Replace spectrum /24 and %24 with horizontal cell counters.
- Cache numeric display fields as registered BCD, outside coordinate selection.
- Register character selection with next-pixel lookahead, preserving alignment.
- Cache the static text line one pipeline stage ahead of character selection;
  test line transitions, page changes and frame wrap explicitly.
- Clip shifted waveform samples before an eight-bit coordinate subtraction;
  exhaustively compare all signed samples and display gain shifts with the
  original wide subtract/clip behavior. Audio PCM is not modified.
- Fix instrument label and remove two-timbre-only ID remapping.
- Fix simultaneous physical NOTE_ON/mapped NOTE_ON display update priority.

No synthesis warnings were disabled, no timing clocks slowed, and no display,
BLE, joystick, FSR or audio feature was removed to lower utilization.

After the brighter bell update: Logic 99105/138240, registers 37456/139095,
BSRAM 114/340. Estimated audio Fmax 19.350 MHz (12.288 MHz target), pixel
Fmax 34.854 MHz (33.333 MHz target). These are pre-route estimates, not
post-route timing closure. Pixel margin is smaller in this full rebuild,
despite no LCD source changes. The final run log is `synthesis_bell_bright_stdout.log`.
The bell changes are documented in BELL_DYNAMICS.md and checked at the full
default duration against the independent envelope implementation.

## Validation Boundaries

Run `tools/verify_merged.ps1` with the local Icarus path. Tests cover module
behavior and top-level structural compilation with a PLL simulation stub.
Phone tests are `node --test app_test.cjs protocol_test.cjs` in `tools/phone`.
Display preview uses synthetic waveform/status data, not a hardware capture.
`tb_adc_expression_merge` tests all three SPI channels with FSR and joystick
active together, including Y-axis isolation and invalid-transaction recovery.
Use `-SkipAudio` when running the audio smoke separately with ModelSim via
`tools/check_merged_audio.do`; the shared-arithmetic audio test is slow in Icarus.

The audio smoke test uses shortened envelope/ring parameters and a low master
gain for a full-velocity 32-note chord. It does not establish default-duration
release correctness, acoustic quality or PCM equivalence to audition files.
An initial 32-note high-gain run asserted mix saturation; the test gain was
reduced, not the production gain. Hardware should check maximum-chord headroom.

Old guitar-reference equivalence failures have not been resolved by this merge.
Final PNR timing and physical keyboard/ADC/PCM5102A/BLE operation still require
board-level acceptance. No new local bitstream is certified by synthesis alone.

# Current Integrated Instrument

## Local Source Update: October 22, 2026

The K230 now has a dedicated 115200 8N1 UART input on J13-35 / C20,
independent of the existing BLE pins C18/C19. It sets volume in five-percent
steps and selects piano/guitar/bell with IDs 0/1/2. The shared parameter
manager updates audio, LCD state and the encoder's next starting value.
K230 uses external 5 V power; connect its 3.3 V TX and common GND only.

K230 files and wiring: [`../../k230_gesture_test/FPGA_UART_WIRING.md`](../../k230_gesture_test/FPGA_UART_WIRING.md).
FPGA details: [`docs/K230_UART.md`](docs/K230_UART.md).
42 Python checks, the dedicated UART/encoder test, volume mapping,
three-timbre master-volume and BLE regression passed; the integrated top
also passed structural compilation with a PLL stub. No physical UART test,
Gowin synthesis, placement/routing or new programming image was performed.
The October 18 prebuilt image below does not contain these source changes.

## Local Source Update: October 21, 2026

Portamento now starts only when a new note overlaps another held key.
The first note after all keys are released starts directly at its target pitch;
release tails do not trigger a glide. See `docs/LEGATO_GLIDE_SEMANTICS.md`.
ModelSim checks for glide, the 32-voice core and EC11_B controls passed, along
with dashboard regression and PLL-stub top-level elaboration
(`tools/verify_legato.ps1`). The dashboard now keeps GLIDE on its own line,
showing ON/OFF and the retained time preset in milliseconds. Recording status
and count appear on the following line without overwriting GLIDE. Dedicated
analysis/TEST pages keep their own contents.
The prebuilt image and resource/timing reports below remain the October 18
release; they do not contain or validate this source change. Rebuild the
fixed-top project before testing the new interaction on hardware.

## Open And Program

- Project: `project/instrument_fixed_top/instrument_fixed_top.gprj`
- Top: `instrument_24_rgb_top`
- Device: `GW5AST-LV138PG484AC1/I0`, version C.
- Programming image: `prebuilt/instrument_fixed_top.fs`
- Checksum: `prebuilt/SHA256SUMS_fixed_top.txt`
- Keep the relative source tree and the project's process configuration.

## Current Release

Includes B's `ff77df9` white LCD/phone theme and dedicated TEST page,
plus local K06/K13 measured calibration, guitar gain/excitation dynamics,
higher master-volume mapping and FSR startup baseline/noise rejection.
FSR must be unloaded during the first 16 successful CH0 samples after reset.
Keyboard velocity remains a calibrated five-level approximation.

The user completed placement/routing on October 18, 2026. The programming
image was generated at 17:10:44 (Asia/Shanghai), with the build finishing
at 17:10:52. The copied image was SHA-256 checked against the build output.
This image supersedes the earlier 16:26 image.

Logic: 96012/138240 (70%); registers: 35903 (26%); CLS: 84%;
BSRAM: 139/340 (41%); DSP: 142/298 (48%). Placement/routing took 13m38s.
Current build evidence is `reports/instrument_fixed_top.rpt.txt`,
`reports/instrument_fixed_top.log` and the matching timing HTML files.
Other dated reports describe older builds.

PR1014 input-clock routing remains in the build log. Successful bitstream
generation is not a claim of timing closure or board/audio acceptance.
The latest volume, guitar and key calibration still need hardware listening.

## Verification

```powershell
powershell -ExecutionPolicy Bypass -File tools/verify_merged.ps1 -SkipAudio
```

Module regression including keyboard, guitar dynamics, FSR and top-level
structural compilation passed before importing B's UI update.
The dedicated TEST-page test passed after that import.
Full long audio/polyphony integration tests have not completed; do not count
them as passing. PLL-stub compilation does not validate physical clocking.

## Cleanup

The obsolete two-timbres project entry and programming image are removed
from this release. Older documentation is historical where it references
that entry; use only the fixed-top project above.
Team-owned branches and historical commits are retained.

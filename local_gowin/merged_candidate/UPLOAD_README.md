# Current Integrated Instrument

## Open And Program

- Gowin project: `project/instrument_velocity_32_two_timbres/instrument_velocity_32_two_timbres.gprj`
- Top module: `instrument_24_rgb_top`
- FPGA: `GW5AST-LV138PG484AC1/I0`, device version C.
- Supplied programming image: `prebuilt/instrument_velocity_32_two_timbres.fs`
- Rebuilt programming images are generated under the project's `impl/pnr/`
  directory. Gowin does not automatically update `prebuilt/`.
- Project source paths are relative. Keep this directory's structure intact.

The project retains its upstream "two_timbres" filename, but enables piano,
guitar and bell with 32 voices.

## Included Functionality

24 dual-contact keys and velocity, two EC11 controls, MCP3008 sampling,
FSR vibrato, joystick pitch bend, glide, audio delay, LCD dashboard and
temporary key-strike calibration display, BLE/phone control, lesson guidance,
keyboard LEDs, polyphony test mode, and PCM5102A I2S output.

Sources, constraints, testbenches, verification scripts, phone web files,
documentation, selected audition WAV files and build evidence are included.
Compiler libraries, placement databases, intermediate netlists and scratch
directories are intentionally excluded.

## Build And Verification

From this directory:

```powershell
powershell -ExecutionPolicy Bypass -File tools/verify_merged.ps1 -SkipAudio
```

This runs 20 module tests and a top-level structural compile using a PLL stub.
It does not validate physical clocking or board behavior.

```tcl
gw_sh tools/build_velocity.tcl syn_only
gw_sh tools/build_velocity.tcl
```

The first command synthesizes only; the second also runs placement and routing.
Audio smoke tests are separately available in `tools/check_merged_audio.do`.

Publication checks: all 20 module tests, top-level structural compilation and
both phone web test suites passed again on 2026-10-16. The ModelSim audio smoke
test and physical build were not rerun for publication.

## Build Evidence And Limits

The included programming image was generated on 2026-10-16 at 17:59:40
(Asia/Shanghai). The placement log records successful placement, routing and
bitstream generation, finishing at 17:59:46.

The `reports/` directory contains captured synthesis and routing reports.
`reports/pnr.log` and `reports/synthesis.log` are separate build logs.
`prebuilt/SHA256SUMS.txt` identifies the exact supplied programming image.
No new synthesis or placement/routing is run merely to publish this snapshot.
Successful bitstream generation is not proof of complete timing closure or
hardware acceptance.

Remaining diagnostics include NL0002 optimized lookup instances, CK3000
audio/pixel PLL clock relationships during synthesis, and PR1014 input-clock
routing. These have not been eliminated; see `docs/WARNING_AUDIT.md`.
Final external I/O timing and integrated hardware/audio acceptance remain
necessary.

Older documents describe earlier intermediate versions and test scopes.
This entry describes the published snapshot and supersedes older statements
that the merged project has no newly generated programming image.

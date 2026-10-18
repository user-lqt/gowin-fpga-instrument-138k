# Current Integrated Instrument

## 当前版本：2026-10-18 白色界面与独立 TEST 页

正确入口：[`project/instrument_fixed_top/instrument_fixed_top.gprj`](project/instrument_fixed_top/instrument_fixed_top.gprj)，顶层为 `instrument_24_rgb_top`。必须保留该工程 impl 目录下的 `instrument_fixed_top_process_config.json`。

相对上次 GitHub 发布的 `47b28fd`，修改了白底 RGB 屏幕与手机网页、K6 的界面呈现，以及独立 32 复音 TEST 页。完整差异、使用方式、烧录文件来源与验证边界见 [CHANGELOG_20261018.md](CHANGELOG_20261018.md)。手机网页版本为 **20261018a**。

本次由用户执行综合、布局布线；发布使用用户本地 2026-10-18 16:26 生成的 `instrument_fixed_top.fs`，上传时进行 SHA-256 对照。我没有重新综合、布局布线或上板实测。完整音频联合长仿真未跑完，不计为通过。

以下旧入口和旧构建记录仅供历史参考，以本节与更新说明为准。

2026-10-16 B fixes: read [FIXES_20261016.md](FIXES_20261016.md) first.
The supplied `prebuilt/*.fs` is the unchanged A baseline, NOT the fixed firmware.
Rebuild the project yourself to use the fixes. No synthesis or place/route was run for this update.

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

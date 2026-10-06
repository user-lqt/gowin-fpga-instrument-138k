# 分支与工作目录索引（2026-10-06）

本表区分整机代码、A 的音频代码和已验证的历史版本。独立分支尚未全部集成，
不能仅凭分支提交就认定整机已上板验收。本次整理没有删除历史文件、目录、分支或烧录文件。

| 用途 | 分支 / 来源提交 | 本地目录 | 当前状态 |
| --- | --- | --- | --- |
| C 的整机集成入口 | `integration/c-stage3`，基于 `origin/joystick` 的 `2b59eef` | `E:\GowinProjects\synth_top_integration_latest` | 24 键、RGB、双 EC11、MCP3008；现有音频核心仍是 4 声部 |
| A 的最新音频参考 | `review/audio-stage3`，跟踪 `origin/dev-audio` 的 `6035c11` | `E:\GowinProjects\synth_top_audio_latest` | 32 声部、三音色源码；尚未加入整机工程 |
| FSR 参考 | `feat/fsr-mcp3008`，`508480c` | `E:\GowinProjects\synth_top_fsr` | 已有分压估值；尚未进行整机接入和上板校准 |
| 已上板 EC11 快照 | 本地 `archive/board-tested-2026-10-04`，`3f315f2` | 以 Git 引用保留 | 历史 J13 EC11 可回退基线 |
| 原 C 工作目录 | `feature/c-24-key-rgb`，`071d8f7` | `E:\GowinProjects\synth_top` | 含未提交历史工作，保持原样 |

`main` 仍停在 `1b47f25`，不是当前整机版本。`origin/shuyou10.4` 是旧的
远程跟踪引用；当前 GitHub 分支列表已无此分支，历史提交由本地归档分支保留。
其余旧开发和评阅分支均保留以便追溯。

## 当前文件

- 整机 IDE 工程：`project/instrument_24_rgb_top/instrument_24_rgb_top.gprj`
- 整机构建脚本：`tools/build_instrument_24_rgb.tcl`
- 当前整机烧录文件：`project/instrument_24_rgb_top/impl/pnr/instrument_24_rgb_top.fs`
- 双 EC11 历史烧录文件：`project/instrument_24_rgb_dual_ec11/impl/pnr/instrument_24_rgb_dual_ec11.fs`

当前整机烧录文件已有 ADC 采样逻辑，但摇杆尚不能改变声音。A 的 32 声部
代码需要先接入工程、综合、检查时序、回归并上板，才能形成新的整机烧录文件。
下一步应在本集成分支接入音频源码、更新 Gowin 源文件清单、核对参数 ID 和
完成整机验证。在结果验收前保留 `main` 和所有历史产物。

# 2026-10-18 发布说明：白色界面与独立 32 复音 TEST 页

对比基线：上次上传分支 `fix/b-integrated-20261016` 的提交 `47b28fd6f56fbcdb5ef7d0f2d9e9f3e085f682c8`。
来源目录：用户指定的 `E:/Gowin/Prj_music/instrument_integrated_fixed_20261016`。

## 工程入口与烧录

- 正确入口：`project/instrument_fixed_top/instrument_fixed_top.gprj`。
- 顶层：`instrument_24_rgb_top`；芯片：`GW5AST-LV138PG484AC1/I0`。
- 保留 `project/instrument_fixed_top/impl/instrument_fixed_top_process_config.json`，其中 `TopModule=instrument_24_rgb_top`。
- 本次发布烧录文件：`prebuilt/instrument_fixed_top.fs`，取自用户本地 `project/instrument_fixed_top/impl/pnr/instrument_fixed_top.fs`，本地修改时间为 2026-10-18 16:26:16（北京时间）。校验文件为 `prebuilt/SHA256SUMS_fixed_top.txt`。
- 此文件是用户在本地生成的构建产物；本次上传没有由助手重新综合、布局布线或烧录。文件存在与校验一致不等于时序收敛、上板显示或音频验收通过。
- 旧工程 `instrument_velocity_32_two_timbres.gprj` 与旧烧录文件仅保留作历史资料，不作为本次入口。历史 reports 不能当作本次重新构建的验收结论。

## 相比上一版本的修改

1. **RGB 屏幕白色主题**：由深蓝背景改为白底、深色文字和细边框，蓝色波形/频谱、紫色单声道延迟 XY、绿色按键反馈。修正中间视觉版本中超出 RGB666 0～63 范围的色值。
2. **手机网页白色主题**：白底、白色卡片与输入区、蓝色按钮、深色文字，减少装饰。版本号更新为 `20261018a`，脚本 URL 同步更新以刷新缓存；蓝牙协议和控制流程不变。
3. **K6 的界面呈现**：屏幕不再把 K6 单独灰显，与其他键使用相同规则；网页说明、错误提示和示例注释中删除禁止/故障 K6 文案。内部曲谱校验仍避开 K6，内置歌曲也仍避开该键；本次没有修复其物理硬件，也没有放开 K6 曲谱下载。
4. **独立 TEST 页面**：主页删除原有 TEST ON/OFF。TEST 专页显示音频核心实际活动声部数 `ACTIVE xx/32`、32 格计数条、测试状态、MIDI 48～79 的混音波形、混音频谱及 XY。32 格是活动声部数量，不是各声部的独立幅度。
5. **分析含义明确**：频谱沿用真实混音的 16 个选定频点 DFT，相对幅度、未校准，不是完整精密 FFT，也不是 32 路独立频谱；XY 使用单声道当前样本与延迟 24 点（48 kHz 下 0.5 ms）的样本，不是双声道相位分析。没有增加 32 套频谱分析器。
6. **增加验证与实测说明**：新增 TEST 页计数/字形/格数测试，扩展 32 声部混音频谱与停止后清除测试，并提供上板验收步骤。`verify_merged.ps1 -SkipAudio` 跳过两项音频核心长测试，保留显示、分析器等检查。

EC11_A 音量、EC11_B 原有页序与长按控制、音色及力度算法、32 声部测试音源、I2S/PCM5102A、GPIO、FSR、蓝牙协议及曲谱推进逻辑没有因本次视觉修改而改变。上一版 VOL 显示、音量提高、下载后启动指引、《小星星》第二曲等修复继续保留。

## 操作

短按 EC11_B：GLIDE → FX → SONG → TEMPO → TEST → ANALYSIS → GLIDE。
在 TEST 页长按 EC11_B（约 0.8 秒）启动/停止测试；启动加载完成后检查 ACTIVE 32/32 与 32 格蓝条。
切页不会自动停止测试，需回 TEST 页长按停止。停止后松开全部实体键，恢复正常输入。
在 ANALYSIS 页旋转 EC11_B 选择频点，查看 Hz 与相对幅度。

手机部署替换整个 `tools/phone/`，重新打开 HTTPS 网页并确认页面版本 `20261018a`。

## 验证结果与边界

通过：`tb_test_dashboard`、`tb_merged_dashboard`、`tb_audio_visualizer`、`tb_fx_wave`、`tb_controls_display`、顶层结构编译，以及手机 `protocol_test.cjs` 和 `app_test.cjs`。

已渲染并检查 800×480 TEST 页仿真预览；预览使用测试激励，不是板上实测截图。

扩展后的 `tb_polyphony_test` 编译通过，但共享运算版音频核心在 Icarus 中的联合仿真耗时较长，本次停止后未取得 PASS，不能称为完整 32 声部联合仿真通过。本次也没有完成上板波形/频谱/XY 实测和时序验收。

具体检查步骤见 [docs/TEST_DISPLAY_VALIDATION.md](docs/TEST_DISPLAY_VALIDATION.md)。

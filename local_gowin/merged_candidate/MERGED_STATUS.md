# 本地完整工程状态

最新发布入口为 `project/instrument_fixed_top/instrument_fixed_top.gprj`，顶层配置与用户 20:01 构建的 `prebuilt/instrument_fixed_top.fs` 一并发布。用户已确认可用。以下旧入口不再推荐。

2026-10-16：在成员 A 的 `d7198b2` 基础上修复音量显示、下载曲谱指引、替换第二曲并提高音量，详见 [FIXES_20261016.md](FIXES_20261016.md)。旧构建报告和 prebuilt 均为历史结果，本次未综合或布局布线。

## 来源与入口

- 屏幕、蓝牙、手机网页、PCM5102A：`integration/b-current-20261015`，提交 `75e652fa900900c3facd5a7f67c072cc5556ecec`。
- 摇杆对比：`feature/c-joystick-bend-test-20261015`，提交 `63ef83b38afce4d1a961b3f8b48716b63a921f48`。
- 音频：保留本地三音色、32 声部、共享运算与 RAM 状态优化，没有用 B 的两音色音频覆盖。
- 工程入口：`project/instrument_velocity_32_two_timbres/instrument_velocity_32_two_timbres.gprj`。
- 顶层：`instrument_24_rgb_top`。工程名称保留上游名称，实际启用三种音色。
- 本次只整合本地 `merged_candidate`，没有提交或推送 GitHub，也没有覆盖 `local_gowin/system`。

## 已整合功能

- 24 键双触点，32 复音，钢琴 / 吉他 / 编钟。
- 双 EC11：音量、三音色切换与功能菜单。
- MCP3008：CH0 为 FSR 颤音，CH1 为摇杆 X 弯音；CH2 读取但暂不控制音频，避免覆盖 FSR。
- 滑音、延迟效果、32 复音验收模式。
- 新版 LCD 波形、16 频点频谱、XY 分析页面与琴键状态。
- BLE 音符、手机网页、琴键映射、演奏记录回传、曲谱下载、节奏与灯光指引。
- 临时力度校准行：主页面 y=400..415，显示最近一次原始 A/B 间隔、键号、力度值。
- PCM5102A 标准 Philips I²S，24 位数据、每声道 32 位时隙、每帧 64 BCK。接线以 `docs/PCM5102A_I2S_WIRING.md` 为准。
- 编钟按用户反馈继续提亮：降低基音权重，突出上方共鸣与金属敲击泛音，最长约 4 秒，松键不截断。见 `docs/BELL_DYNAMICS.md`。

## 摇杆选择

采用 C 的接口行为和测试，结合本地位宽优化。两者平均滤波、死区、端点校准和 SPI 异常回中策略本质相同；
修正了本地优化版把 `MAX_BEND` 系数写死的问题。默认中心为 512，实体摇杆仍需实测校准。
没有采用 C 的旧两音色、板载 DAC 完整顶层作为整合底座。

## 验证结果

- Icarus：19 项模块回归通过，包括参考模态参数、独立/RAM 编钟逐样本一致、编钟尾音分配策略、编钟默认完整时长、四路参数队列、三通道 ADC 联合链路、摇杆全 ADC 扫描、非默认弯音范围、力度格式化、屏幕换行/换页/帧回绕、I²S 实际引脚解码、蓝牙、灯光、可视化、滑音、24 键双触点。
- 三通道 ADC 联合仿真验证 CH0/1/2 轮询、实际 SPI 数据、弯音端点、FSR 对颤音参数的独占及异常恢复；不是实物接线验证。
- 屏幕波形坐标缩窄经过全部 65,536 个有符号样本和 16 档显示增益的等价检查。
- 顶层结构编译通过；PLL 使用仿真桩，不代表 PLL 和时序验收。
- Node：手机网页与协议两项测试通过。
- ModelSim：三种音色各自 32 声部冒烟测试通过，检查 PCM 非零/无未知、256 周期输出节拍、表情参数和释放回收。
- 音频测试缩短了释放/编钟余音时间，并降低了测试用主增益；不证明默认完整余音、试听 PCM 一致或真实听感。
- 编钟另用 `tb_bell_envelope` 验证默认完整余音、点按/长按一致、重触发，以及共享/独立包络逐样本一致；它不替代最终听感。
- 编钟旧旋律试听存在四声部每 1.6 秒覆盖的问题；不代表完整余音。
  新试听采集六个音高的完整 RTL 短按后离线独立叠加：5 秒单音、10 秒《小星星》、
  6 秒三连音停顿，输出为 `sim/merged_checks/bell_full_tail_tap.wav`、
  `bell_full_tail_twinkle.wav`、`bell_tail_overlap_demo.wav`。
  没有走完整生产分配器/混音器/FX/I²S；具体渲染检查见 `bell_audition_report.json`。
- 32 个满力度音符在较高测试增益下出现过混音饱和，需上板核查最大和弦余量；没有为通过测试而修改生产音量。

## 综合与待验收

清亮调整后完整工程综合成功；未运行布局布线：

| 资源 | 用量 |
| --- | ---: |
| Logic | 99105/138240，约 71.7%（Gowin 向上显示 72%） |
| LUT / ALU / RAM16 | 78912 / 19071 / 187 |
| 寄存器 | 37456/139095，约 26.9%，无锁存器 |
| BSRAM | 114/340，约 33.5% |

| 时钟 | 约束 | 综合估计 Fmax |
| --- | ---: | ---: |
| 音频 | 12.288 MHz | 19.350 MHz |
| LCD 像素 | 33.333 MHz | 34.854 MHz |

LCD 综合估计从初次整合的 25.074 MHz，经字符流水线、BCD 缓存、静态行缓存与波形坐标优化，
提高到 37.793 MHz；上一版估计为 39.545 MHz，本次全工程重新综合估计为 34.854 MHz。
没有修改 LCD 源码、降低时钟目标或关闭功能；本轮 LCD 估计余量较小，仍须实际布局布线确认。
这只是综合估计满足目标，不是布局布线后时序通过。
仍有位宽截断、未使用实例裁剪和双 PLL 关系 CK3000 等警告，未屏蔽；异步跨域及外部 I/O 预算仍需时序验收。
最终综合日志：仓库根目录 `tmp/team_merge/synthesis_bell_bright_stdout.log`。
报告：`project/instrument_velocity_32_two_timbres/impl/gwsynthesis/instrument_velocity_32_two_timbres_syn.rpt.html`。
相对上一版，Logic 增加 318，寄存器减少 8，BSRAM 不变；共享参数模块已列入工程。

没有启动布局布线，没有生成本次整合的新 `.fs`。`prebuilt` 和既有 `impl/pnr` 的文件不能当成本次版本。
最终时序、I/O 预算、实际键盘/ADC/FSR/摇杆/蓝牙/PCM5102A 和听感均需后续验收。
旧的吉他参考 PCM 等价性问题不因本次整合而被视为解决。

## 复现

- 模块和顶层：`powershell -ExecutionPolicy Bypass -File tools/verify_merged.ps1 -SkipAudio`。
- 音频：在工程根目录用 ModelSim 执行 `do tools/check_merged_audio.do`。
- 屏幕预览：在工程根目录用 ModelSim 执行 `do tools/check_dashboard.do`，输出 `sim/merged_checks/dashboard_preview.ppm`。
- 手机：在 `tools/phone` 执行 `node --test app_test.cjs protocol_test.cjs`。
- 仅综合：在工程根目录执行 `gw_sh tools/build_velocity.tcl syn_only`。
- 合并决策：`docs/MERGE_DECISIONS.md`；力度字段：`docs/KEY_VELOCITY_CALIBRATION.md`。
- 上游快照、合并前备份及日志位于仓库根目录 `tmp/team_merge`。

# 高云 FPGA 实时多音色合成电子乐器引擎

> **shuyou 当前双 EC11 交付**：完整工程、烧录入口及 A→C 后续分工见
> [当前交接说明](docs/SHUYOU_HANDOFF.md)。成员 A 完成并上传 EC11_A 三音色、
> EC11_B 滑音实现，最后由成员 C 合并验收；滑音/效果声音当前仍待实现。

> **shuyou10.4 当前可用版本**：24 键、RGB 屏及 J13 EC11 已上板反馈可用。
> 工程入口、烧录文件、构建方法和接线见 [2026-10-04 交付说明](docs/SHUYOU_2026_10_04.md)。
> EC11 使用 J13 的 A21/B21/B18，不再使用旧 PMOD 接线图。
> 后续正式交互版：旋转始终调音量、短按循环三音色；见
> [EC11 正式交互说明](docs/EC11_FORMAL_CONTROLS.md)，使用独立的新烧录文件。
> 双旋钮菜单版接线和入口见 [EC11_B 滑音／效果菜单](docs/EC11_B_WIRING.md)。
> B 端参数发送已实现，滑音和效果声音处理仍待成员 A 接入。
> MCP3008/摇杆已接入顶层但尚未接入音频算法；见
> [MCP3008与摇杆 RTL 说明](docs/JOYSTICK_MCP3008_RTL.md)。
> 当前已根据最新分配接入顶层：J13-24/25/26/27 = ADC_CS/SCLK/MOSI/MISO。
> ADC/摇杆分支交接（成员 A 完成弯音/调制，成员 C 最后合并）见
> [JOYSTICK_HANDOFF.md](docs/JOYSTICK_HANDOFF.md)。

> 全国大学生嵌入式芯片与系统设计竞赛 2026 · FPGA 创新设计赛道 · **高云半导体 选题二**
> 平台：**Sipeed Tang Mega 138K Dock** · 芯片 **GW5AST-LV138PG484AC1/I0**

这是一台**由演奏动作驱动、由 FPGA 硬件逻辑逐样本生成声音**的实时电子乐器。

系统的核心属性（也是评分依据）：

- 音频通路的每一个样本都由 FPGA 在硬件逻辑层实时计算，**不是预录 PCM 播放**
- 演奏动作 → 事件 → 声部 / 振荡器 → 混音 → I2S → DAC，端到端延迟 **≤ 10 ms**（冲刺 ≤ 5 ms）
- 基础目标：**≥ 4 复音**、**≥ 2 个独立演奏维度**、独立 ADSR、实时变调
- 冲奖目标：**≥ 32 独立振荡器**、**≥ 3 维表情**、**≥ 2 种音色**、硬件音效、可视化反馈

---

## 一、团队成员与任务的唯一入口

**每个人只读自己那一份任务书，不要读别人的。** 任务书是你在本仓库中的权限边界说明书。

| 成员 | 任务书 | 负责目录 | 独立工程 | 分支 | Git 账号 |
|---|---|---|---|---|---|
| **A** 音频合成与音质优化 | [`docs/成员A_音频合成与音质优化任务书.md`](docs/成员A_音频合成与音质优化任务书.md) | `rtl/audio_core/`、`sim/audio_core_tb/` | `audio_core_sim.gprj` | `dev-audio` | TODO 填写 |
| **B** 演奏输入与参数界面 | [`docs/成员B_演奏输入与参数界面任务书.md`](docs/成员B_演奏输入与参数界面任务书.md) | `rtl/input/`、`rtl/ui/`、`sim/input_ui_tb/` | `input_ui_sim.gprj` | `dev-input` | TODO 填写 |
| **C** 音频输出与 FPGA 系统平台 | [`docs/成员C_音频输出与FPGA系统平台任务书.md`](docs/成员C_音频输出与FPGA系统平台任务书.md) | `rtl/system/`、`rtl/common/`、`project/`、`constraint/`、`tb/` | `audio_system_sim.gprj`、`synth_top.gprj` | `dev-system` | TODO 填写 |

先读 [`docs/高云FPGA电子乐器项目总计划书_最终版.md`](docs/高云FPGA电子乐器项目总计划书_最终版.md)（总控与作战手册），再读自己的任务书，最后只浏览另外两人的"接口与边界"章节。

**开工前必须先读的三份文件**

1. [`docs/PLATFORM_TANG_MEGA_138K.md`](docs/PLATFORM_TANG_MEGA_138K.md) —— 板卡与器件、IDE 版本、管脚、安全红线
2. [`docs/INTERFACE_FREEZE.md`](docs/INTERFACE_FREEZE.md) —— 接口冻结卡、采样率/位宽/定点、延迟预算
3. [`docs/GIT_WORKFLOW.md`](docs/GIT_WORKFLOW.md) —— 分支、提交、合并、评审规则

**成员 C 另需先读**：[`docs/C_官方例程与板载音频通路分析.md`](docs/C_官方例程与板载音频通路分析.md) —— 已核实板载 DAC/功放通路与实机 I2S 管脚，是 C1 出声的第一步依据。

---

## 二、仓库结构

```
gowin-fpga-instrument-138k/
├─ README.md                     本文件
├─ rtl/
│  ├─ common/                    ★ C 维护，A/B/C 共用（改动必须通知全员）
│  │  ├─ event_defs.vh           事件/参数/音频的唯一契约
│  │  ├─ status_defs.vh          状态与错误码
│  │  └─ reset_sync.v            复位同步器
│  ├─ audio_core/                A 独占：DDS、波表、FM、ADSR、声部、混音
│  ├─ input/                     B 独占：键盘、编码器、触摸、力度、滤波
│  ├─ ui/                        B 独占：参数管理、页面状态与内容
│  └─ system/                    C 独占：时钟、采样节拍、I2S、音效、状态
├─ sim/
│  ├─ audio_core_tb/             A：tb_audio_core.v + audio_core_sim.gprj
│  └─ input_ui_tb/               B：tb_input / tb_encoder / tb_sensor / tb_ui
├─ tb/                           C：系统级 testbench（如 tb_top_integration.v）
├─ project/                      C 独占：synth_top.v、各 *.gprj
├─ constraint/                   C 独占：tang_mega138k.cst / .sdc
├─ docs/                         任务书、计划书、平台卡、接口冻结、采购清单
├─ tools/                        仿真与综合辅助脚本
├─ waveforms/                    保存的仿真波形配置与截图
└─ evidence/                     验收证据：综合报告、时序、延迟、频谱
```

`tools/`、`waveforms/`、`evidence/` 三个目录共用，命名规则见 `docs/GIT_WORKFLOW.md`。

---

## 三、三条铁律

1. **只改自己的目录。** 需要改别人的东西 → 先提接口变更说明，不要直接改。
2. **接口以 `rtl/common/event_defs.vh` 为唯一真相。** 字段/位宽/编码不一致时，以该文件为准。
3. **不进版本库的东西：** Gowin 的 `impl/`、`*.fs`、`*.ipc`、`*.log`、`.temp/`、bitstream、PDF 手册、仿真缓存 —— 见 `.gitignore`。

---

## 四、常用 Git 命令（三分钟上手）

```bash
# 第一次：克隆
git clone https://github.com/user-lqt/gowin-fpga-instrument-138k.git
cd gowin-fpga-instrument-138k
git config user.name  "你的名字"
git config user.email "你的邮箱@example.com"

# 切到自己的开发分支
git checkout dev-audio      # A 用
git checkout dev-input      # B 用
git checkout dev-system     # C 用

# 日常：改代码 → 提交 → 推送
git status
git add rtl/audio_core/phase_acc.v
git commit -m "feat(audio): 实现 32 位相位累加器与波表寻址"
git push

# 开始新工作前，先同步主干（避免长期偏离）
git fetch origin
git merge origin/main       # 或 git rebase origin/main

# 功能做完 → 发 Pull Request 合并到 main
gh pr create --base main --head dev-audio --title "stage1: 单音 DDS 通路" --body "见 testbench 结果"
```

完整规则（分支命名、提交信息规范、PR 检查单、冲突处理、阶段标签）见
[`docs/GIT_WORKFLOW.md`](docs/GIT_WORKFLOW.md)。

---

## 五、阶段与 Git 标签

| 阶段 | 目标 | 通过后打的标签 |
|---|---|---|
| **阶段 0** | 三个独立工程可打开、三个 testbench 可运行、接口冻结 | `stage0-freeze` |
| **阶段 1** | 三条独立最小链路（单音合成 / 键盘输入 / I2S 出声） | `stage1-minimal` |
| **阶段 2** | 基础可提交版本：≥4 复音、2 维交互、≤10 ms | `stage2-baseline` |
| **阶段 3** | 冲奖扩展：32 振荡器、3 维表情、音色、音效、≤5 ms | `stage3-award` |
| **阶段 4** | 成品化与比赛现场冻结 | `stage4-final` |

**`stage2-baseline` 是保底线。** 冲奖开发一旦破坏它，立即回退到该标签版本，删掉风险最高的功能。

---

## 六、当前状态

- [x] 官方赛题与宣讲材料归档
- [x] 团队总计划书与三份个人任务书归档
- [x] 硬件采购清单归档
- [x] 平台与器件信息核实（Tang Mega 138K）
- [x] 仓库骨架 + 接口文件冻结草案
- [ ] **阶段 0**：三个 Gowin 工程建立、三个 testbench 跑通、接口正式冻结
- [ ] **阶段 1**：单音 DAC 出声
- [ ] **阶段 2**：基础可提交版本

阶段 0 的验收清单见 [`docs/INTERFACE_FREEZE.md`](docs/INTERFACE_FREEZE.md) 最后一节。

---

## 七、免责与合规

- 所有输出音频均由 FPGA 依据实时演奏指令逐音、逐样本生成；**严禁**播放预录 PCM、预置推流或整段录音触发。
- 外接 GPIO **只允许 3.3 V 电平**；任何 5 V 输出必须分压或电平转换后才能接入 FPGA。
- 功放为 BTL 差分输出，扬声器负端**不得接地**，左右声道负端不得互连。

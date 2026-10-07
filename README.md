# 高云 FPGA 实时多音色合成电子乐器引擎

> **当前整机唯一入口：`integration/c-stage3`。** 工程为
> `project/instrument_24_rgb_top/instrument_24_rgb_top.gprj`，现有烧录文件为
> `project/instrument_24_rgb_top/impl/pnr/instrument_24_rgb_top.fs`。
> 正式分支、工作目录和历史版本见 [分支整理记录](docs/GITHUB_BRANCH_CLEANUP.md)。
>
> **当前整机仍为 4 声部。** A 已在 `dev-audio` 的 `6035c11` 交付 32 声部和
> 钢琴、吉他、编钟，待 C 集成、构建并上板验收。力度开发由 B 负责，力度改变
> 音量、泛音和音色，基频保持不变；旧固件慢按降八度属于历史行为。
> 摇杆 ADC 已接入整机，但弯音、滑音、FSR 颤音和音效尚未完成整机验收。
> 当前功能、分工与下一步以 [当前状态与任务](docs/CURRENT_STATUS.md) 为准。
>
> 双 EC11 接线见 [接线说明](docs/EC11_B_WIRING.md)，ADC 接线见
> [MCP3008 与摇杆说明](docs/JOYSTICK_MCP3008_RTL.md)。
> 已上板的单 EC11 历史版本保存在 `board-j13-ec11` 标签，
> [旧交付说明](docs/SHUYOU_2026_10_04.md) 仅对应该版本。

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

# 模块交付 → 发 Pull Request 到唯一整机入口
gh pr create --base integration/c-stage3 --head dev-audio --title "audio: 音频模块交付" --body "见测试证据及待验收范围"
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

- 24 键、RGB、双 EC11 和 MCP3008 采样代码已有整机入口；单 EC11 上板基线与双 EC11 历史交付均可按标签追溯。
- 整机仍为 4 声部；A 的 32 声部、钢琴/吉他/编钟交付位于 `dev-audio`，尚未进入现有整机烧录文件。
- FSR 校准映射及触点顺序修复保留独立分支，整机兼容处理待完成。
- 弯音、滑音、FSR 颤音、音效和最终力度方案需要整机集成与验收；64 声部候选尚非远程整机成果。
- `main` 保留原发布版本，只通过验收 PR 更新；分支整理不等于阶段验收。

阶段 0 的验收清单见 [`docs/INTERFACE_FREEZE.md`](docs/INTERFACE_FREEZE.md) 最后一节。

---

## 七、免责与合规

- 所有输出音频均由 FPGA 依据实时演奏指令逐音、逐样本生成；**严禁**播放预录 PCM、预置推流或整段录音触发。
- 外接 GPIO **只允许 3.3 V 电平**；任何 5 V 输出必须分压或电平转换后才能接入 FPGA。
- 功放为 BTL 差分输出，扬声器负端**不得接地**，左右声道负端不得互连。

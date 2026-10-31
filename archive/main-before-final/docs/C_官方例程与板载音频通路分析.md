# 官方例程分析 · 板载音频通路（阶段 0 关键证据）

> 归属：成员 C。本文是**平台事实的权威依据**，优先级高于 `PLATFORM_TANG_MEGA_138K.md` 的早期推测。
> 依据来源：Sipeed 官方例程 **`sipeed/TangMega-138K-example` → `audio_i2s/`**
> <https://github.com/sipeed/TangMega-138K-example>

---

## 1. 最重要的结论：板载音频通路是完整的，不需要外置 DAC 和功放

官方 I2S 例程的顶层注释直接回答了我们之前悬而未决的问题：

```verilog
//audio接口
output HP_BCK,   //同 clk_1p536m
output HP_WS,    //左右声道切换信号，低电平对应左声道
output HP_DIN,   //dac串行数据输入信号
output PA_EN,    //音频功放控制；官方 top.v 固定为低电平常开
```

例程说明文档（`audio_i2s.md`）：

> Test condition: earphone in the jack or mounted speaker.
> Phenomenon: A 400 Hz trapezoidal wave is generated and played.

**结论**

| 结论 | 影响 |
|---|---|
| 板载**已有 I2S DAC**（HP_DIN/HP_WS/HP_BCK 直接进 DAC） | ✅ **不需要外置 PCM5102A** |
| 板载**已有功放**，且由 `PA_EN` 控制（官方例程固定低电平常开） | ✅ **不需要 PAM8403 + 独立 5V 电源 + 无源喇叭** |
| 输出口是**耳机口 / 已装扬声器** | ✅ **不需要 3.5mm 有源音箱也能出声** |
| 复位键 = S2，管脚 `F4`，电平域 **1.5V** | ⚠️ IO_TYPE 必须写 `LVCMOS15` |

**采购清单因此可大幅精简**：阶段一原计划的"DAC 模块 + 有源音箱 + 音频线"全部降级为可选，**第一声可以直接用板载耳机口 + 一副耳机验证**。

**但仍需保留一件东西：逻辑分析仪。** I2S 三线的波形必须实测，这是 C1 的硬性验收条件，不能靠"听见了"代替。

---

## 2. 已核实的实机管脚（可直接填入 `.cst`）

来源：官方 `audio_i2s/eda_proj/src/audio.cst`（Tool Version V1.9.9.01，器件 `GW5AST-LV138PG484AC2/I1`，Device Version **B**）

```tcl
IO_LOC  "led"     W21;    IO_PORT "led"     IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_LOC  "PA_EN"   AB16;   IO_PORT "PA_EN"   IO_TYPE=LVCMOS33 PULL_MODE=UP   DRIVE=8 BANK_VCCIO=3.3;
IO_LOC  "HP_DIN"  AA16;   IO_PORT "HP_DIN"  IO_TYPE=LVCMOS33 PULL_MODE=UP   DRIVE=8 BANK_VCCIO=3.3;
IO_LOC  "HP_WS"   AB17;   IO_PORT "HP_WS"   IO_TYPE=LVCMOS33 PULL_MODE=UP   DRIVE=8 BANK_VCCIO=3.3;
IO_LOC  "HP_BCK"  Y17;    IO_PORT "HP_BCK"  IO_TYPE=LVCMOS33 PULL_MODE=UP   DRIVE=8 BANK_VCCIO=3.3;
IO_LOC  "rst"     F4;     IO_PORT "rst"     IO_TYPE=LVCMOS15 PULL_MODE=NONE BANK_VCCIO=1.5;
```

**说明**

- 信号名沿用官方命名（`HP_*`、`PA_EN`），**避免与硬件原理图脱节**
- 官方器件型号写的是 `GW5AST-LV138PG484AC2/I1`，Wiki 写的是 `...AC1/I0`。两者**封装相同（PG484）**，差异在速度等级/温度等级与器件版本。**以实物丝印为准**，管脚位置不受影响。
- 器件版本官方例程写 **B**，Wiki 说"按实际情况选 B/C"。上板前用丝印复核。

---

## 3. I2S 协议：官方实测的参数（含一处必须修正的位宽）

### 官方例程的实际做法

```verilog
//audio_drive.v 关键逻辑
assign HP_BCK = clk_1p536m;              // BCK = 1.536 MHz
// 每个采样点占 32 个 BCK（左右声道各 16）
req_r <= (b_cnt == 5'd0) || (b_cnt == 5'd16);   // 半帧边界请求新数据
HP_WS_r <= (b_cnt == 5'd3) ? 1'b0 : ((b_cnt == 5'd19) ? 1'b1 : HP_WS_r);
idata_r <= req_r1 ? idata : idata_r << 1;       // 左移串出，MSB 先出
HP_DIN_r <= idata_r[15];
```

**推导出的规格**

| 参数 | 官方值 | 说明 |
|---|---|---|
| BCK | 1.536 MHz | 位时钟 |
| 帧长 | 32 BCK | 左右声道各 16 bit |
| LRCK (WS) | **48 kHz** | 1.536 MHz / 32 ✅ |
| 每声道位宽 | **16 bit** | 硬件支持的格式 |
| 数据顺序 | MSB 先出 | 平移寄存器左移 |
| WS 相位 | 在 b_cnt=3 置 0（左）、b_cnt=19 置 1（右） | **不是标准 I2S 的 1-BCK 延迟，而是偏 3 个 BCK** |

### ⚠️ 必须修正的一处：位宽

`INTERFACE_FREEZE.md` 和 `event_defs.vh` 里原本冻结的是 **24 bit / 32bit 槽 / BCK=64×LRCK**（那是为外置 PCM5102A 设计的）。**现在走板载 DAC，必须按它实际支持的格式来。**

**修正后的方案（推荐）**

| 项 | 值 | 理由 |
|---|---|---|
| LRCK | **48 kHz**（不变） | 采样率指标不变，吞吐量口径不变 |
| **BCK** | **3.072 MHz = 48 kHz × 64** | 给 24 bit 留出槽位 |
| 每声道槽位 | **32 BCK** | 24 bit 数据 + 8 bit 补零 |
| 有效位宽 | 先按 **16 bit** 验证，再升 **24 bit** | 见下方"验证阶梯" |
| `PA_EN` | **低电平常开** | 官方可发声 `top.v` 明确 `assign PA_EN = 1'b0` |

**为什么 BCK 用 3.072 MHz 而不是 1.536 MHz**

从 12.288 MHz 音频主时钟出发，两种都除得尽：
- 1.536 MHz = 12.288 / 8 → 只能给 16 bit 槽（32 BCK/帧）
- **3.072 MHz = 12.288 / 4 → 可给 32 bit 槽（64 BCK/帧），从而支持 24 bit 输出**

选 3.072 MHz 让我们**同时保留 48 kHz 采样率和 24 bit 音质**，这也是赛题"高表现力"的加分项。

**验证阶梯（不要一步到位）**

```
第 1 步：完全复刻官方参数（BCK=1.536MHz，16bit，WS 相位照抄）→ 先听到 400Hz 梯形波
第 2 步：把波形换成自己产生的正弦 → 确认我们自己能控制波形
第 3 步：BCK 提到 3.072MHz，槽位 32bit，数据左对齐 24bit → 听音质是否变好、是否仍正常
第 4 步：用逻辑分析仪抓三线，确认 LRCK=48kHz、BCK=64×LRCK、数据对齐
```

**第 3 步有风险**：板载 DAC 可能只接受 16 bit 格式（不认 32 bit 槽）。若第 3 步失败，方案退回 16 bit 槽，并在文档中记录"板载 DAC 限制"，同时把 PCM5102A 外置方案作为**音质升级备选**.

---

## 4. 与官方例程不同、我们必须要做对的地方

官方例程是**演示级**代码，直接照抄会不符合赛题要求。差异清单：

| 项 | 官方例程 | 我们的要求 |
|---|---|---|
| 音源 | 固化 ROM 里的 400Hz 梯形波表，循环播放 | **由演奏事件驱动的实时合成**（严禁预录 PCM 播放） |
| 位宽 | 16 bit | 目标 24 bit |
| 时钟 | `Gowin_OSC` 内部振荡器 50 MHz → PLL → CLKDIV | **外部晶振 + PLL**，生成精确 12.288 MHz 音频域 |
| 声道 | 左右声道送**同一份**数据（单声道复制） | 左右声道独立 `audio_left` / `audio_right` |
| 时序 | 组合逻辑 + 简单计数 | 每声道独立 32bit 槽移位寄存器，锁定相位 |
| 复位 | 官方为 `rst_n = !rst`（S2 按下为高电平复位，松开后运行） | 上电同步复位，复位期间输出静音 |

> **合规红线**：官方例程的 `rom_save_sin` 是**固定波表循环播放**。我们只能用波表作为**振荡器的一个采样点来源**（逐样本按相位寻址），**绝不能**整段读取播放。这正是赛题"振荡器统计规则"要区分的地方。

---

## 5. 阶段 0（C0）立即可执行的动作

### 5.1 已完成（本次）

- [x] 确认板载音频通路类型：**DAC + 功放板载，PA_EN 使能**
- [x] 获取 I2S 三线 + PA_EN + 复位 + LED 的**实机管脚**
- [x] 确认器件版本为 **B**（待丝印复核）
- [x] 写入 `constraint/tang_mega138k.cst`
- [x] 确认板载复位键为 S2，电平域 1.5V

### 5.2 你要做的（按顺序）

| # | 动作 | 产出 |
|---|---|---|
| 1 | 复制官方例程到本地，**完整跑通一次**（看到/听到 400Hz） | 确认下载链路 + License 可用 |
| 2 | 记录你实际用的 **IDE 版本 + License 类型** | 写进 `.cst` 注释与平台卡 |
| 3 | 丝印复核器件版本（B / C） | 修正 `.cst` 与工程器件设置 |
| 4 | 确认**板载晶振频率与管脚**（官方例程用的是内部 OSC） | `.cst` 补 `clk_in` |
| 5 | 确认键盘/OLED/编码器可用的 GPIO 排针管脚 | `.cst` 补齐待办项 |
| 6 | 建立 `synth_top.gprj`，选器件 `GW5AST-LV138PG484A` + PBG484A + 版本 B/C | 阶段 0 工程骨架 |
| 7 | 实现 `clock_gen.v`：外部晶振 → PLL → 100 MHz 系统域 + 12.288 MHz 音频域 | 综合通过、时钟实测 |

### 5.3 然后进入 C1（第一条最小链路）

```
sample_scheduler (48 kHz tick) → i2s_tx (BCK/LRCK/DIN) → 板载 DAC → 耳机口出声
                                      ↑
                       固定正弦 ROM（先替代 A 的音频核心）
```

**C1 验收硬门槛（来自你的任务书）**：
- LRCK 实测 **48 kHz**
- BCK / DATA 对齐正确，无一位错位
- 左右声道稳定，耳机口持续发声
- 没有严重杂音、爆音、周期性中断
- 有逻辑分析仪波形证据

---

## 6. 需要你现场确认的开放问题

| # | 问题 | 影响 |
|---|---|---|
| 1 | 板载 DAC 是否接受 **32 bit 槽 / 24 bit 数据** | 决定能否上 24 bit 音质 |
| 2 | 板载晶振频率与管脚 | 决定 PLL 配置（影响 12.288 MHz 精度） |
| 3 | 器件版本 B 还是 C | 影响综合与烧录 |
| 4 | `PA_EN` 官方例程固定低电平常开；是否存在独立静音控制管脚 | 影响淡入淡出/防爆音实现 |
| 5 | 耳机口与扬声器接口是否可同时输出 | 影响现场演示接线 |

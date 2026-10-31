# 接口冻结卡 · Interface Freeze

> 归属：成员 C 维护。状态：**草案冻结（阶段 0 待评审）**。
> 本文件与 `rtl/common/event_defs.vh`、`rtl/common/status_defs.vh` 必须保持一致；三者冲突时以 `.vh` 为准，并立即修正本文件。

---

## 0. 冻结的三件事

阶段 0 的通过条件是**接口字段、方向、宽度、复位值全部冻结**。冻结后：

- 新增字段 = 向后兼容扩展 → 版本号 +1，通知 A/B，双方 testbench 同步更新
- 修改/删除字段 = **破坏性变更** → 必须全员会议确认，且要说明为什么不能在现有字段上做

当前版本：`EVENTS_DEFS_VERSION = 8'd1`、`STATUS_DEFS_VERSION = 8'd1`

---

## 1. B → A：演奏事件与表情参数

| 信号 | 方向 | 位宽 | 说明 | 复位值 |
|---|---|---|---|---|
| `event_valid` | B→A | 1 | 事件有效脉冲，保持 1 拍 | 0 |
| `event_type[1:0]` | B→A | 2 | 见下方编码 | 0 |
| `note_id[6:0]` | B→A | 7 | MIDI 音符号，A4=440Hz=69 | 0 |
| `velocity[7:0]` | B→A | 8 | 力度 1..127，0 视为无效 | 0 |
| `param_valid` | B→A | 1 | 参数有效脉冲 | 0 |
| `param_id[3:0]` | B→A | 4 | 参数编号 | 0 |
| `param_value[15:0]` | B→A | 16 | 参数值 | 0 |

**事件类型编码**

| 值 | 名称 | 含义 |
|---|---|---|
| `2'd0` | `EVENT_NONE` | 无事件 |
| `2'd1` | `EVENT_NOTE_ON` | 触发音符，使用 `note_id` + `velocity` |
| `2'd2` | `EVENT_NOTE_OFF` | 释放音符，使用 `note_id`；进入 Release 而非硬切 |
| `2'd3` | `EVENT_PARAM_CHANGE` | 参数变化，使用 `param_id` + `param_value` |

**参数编号**

| 值 | 名称 | 值域 / 格式 |
|---|---|---|
| `4'd0` | `PARAM_VOLUME` | 0x0000..0xFFFF 线性音量 |
| `4'd1` | `PARAM_INSTRUMENT` | 低 4 位音色索引（0 起） |
| `4'd2` | `PARAM_PITCH_BEND` | signed，-8192..+8191 ≈ ±2 半音 |
| `4'd3` | `PARAM_MODULATION` | 0x0000..0xFFFF 颤音深度 |
| `4'd4` | `PARAM_FILTER` | 0x0000..0xFFFF 亮度/截止 |
| `4'd5` | `PARAM_EFFECT_MIX` | 0x0000..0xFFFF 干湿比 |
| `4'd6` | `PARAM_GLIDE` | 0x0000..0xFFFF 滑音时间 |
| `4'd7..4'd11` | 预留 | ADSR 四段 + 全局微调 |
| `4'd12..4'd15` | 保留 | 不得占用 |

**握手约定**

- `event_valid` / `param_valid` 与其余字段**同拍有效**，保持 1 拍后撤销
- A **不需要 backpressure**，每个 `sample_tick` 至少吸收 1 个事件
- **B 必须在内部排队**，不得因为 A 未及时消费而丢事件
- B 不得用 `param_id` 传音符事件

---

## 2. A → C：音频采样与状态

| 信号 | 方向 | 位宽 | 说明 | 复位值 |
|---|---|---|---|---|
| `audio_core_valid` | A→C | 1 | 采样有效，与数据同拍，频率 48 kHz | 0 |
| `audio_left[23:0]` | A→C | 24 | 有符号补码，±8388607 满量程 | 0（静音） |
| `audio_right[23:0]` | A→C | 24 | 同上 | 0（静音） |
| `active_voice_count[5:0]` | A→C | 6 | 未完全静音的声部数，饱和值 48 | 0 |
| `engine_ready` | A→C | 1 | 音频核心就绪（波表/参数初始化完成） | 0 |
| `overload_flag` | A→C | 1 | 混音发生饱和/削波 | 0 |

**约定**

- C **不得截断**采样位宽；如需降位宽必须先饱和再移位
- `overload_flag` 为脉冲或电平均可，但必须可被 C 计数（用于资源与音质诊断）
- A 在 `engine_ready = 0` 时必须输出**数值 0（静音）**，不得输出随机值

---

## 3. B → C：界面与状态

| 信号 | 方向 | 位宽 | 说明 | 复位值 |
|---|---|---|---|---|
| `ui_page[3:0]` | B→C | 4 | 当前页面编号 | 0 |
| `ui_param_value[15:0]` | B→C | 16 | 当前页面主参数值 | 0 |
| `key_state[15:0]` | B→C | 16 | 按键位图（调试/LED 用） | 0 |
| `sensor_state[15:0]` | B→C | 16 | 传感器状态位图 | 0 |
| `input_ready` | B→C | 1 | 输入链路就绪 | 0 |
| `ui_dirty` | B→C | 1 | 页面内容已变化，需要重绘 | 0 |

**页面上位机显示用的参数**：`active_voice_count`、`overload_flag`、`system_error`、`audio_locked`（由 C 拼装后送给 B 的显示层）。
**OLED 低级 I2C 驱动归 C**；B 只提供页面数据与 `ui_dirty`，**不得另写一份 I2C 驱动**。

---

## 4. C → 全员：系统状态

| 信号 | 方向 | 位宽 | 说明 | 复位值 |
|---|---|---|---|---|
| `system_ready` | C→AB | 1 | 上电自检完成 | 0 |
| `audio_locked` | C→AB | 1 | 采样节拍与 I2S 锁定 | 0 |
| `i2s_active` | C→AB | 1 | I2S 正在输出 | 0 |
| `system_error[7:0]` | C→ 显示 | 8 | 多热错误码，见下 | 0 |

**错误码**

| 位 | 名称 | 降级策略 |
|---|---|---|
| `0x01` | `ERR_CLK_UNLOCKED` | 静音 + 错误 LED |
| `0x02` | `ERR_SAMPLE_TICK_LOST` | 静音 + 错误 LED |
| `0x04` | `ERR_I2S_UNDERRUN` | 输出静音样本，I2S 不停 |
| `0x08` | `ERR_I2S_OVERFLOW` | 计数告警（不应发生） |
| `0x10` | `ERR_AUDIO_CLIP` | 自动降低总增益 |
| `0x20` | `ERR_INPUT_TIMEOUT` | 该维度回默认值，其余继续 |
| `0x40` | `ERR_PARAM_RANGE` | 钳位 + 告警（可恢复） |
| `0x80` | 预留 | — |

**任何错误都不得导致死机，且必须能通过复位键恢复。**

---

## 5. 定点格式与位宽约定

| 项目 | 约定 | 原因 |
|---|---|---|
| 相位累加器 | **32 bit**，取高 12 bit 作波表地址 | 频率分辨率 1.12e-5 Hz；最低音误差 < 0.001 音分 |
| 波表数据 | signed 16 bit，4096 点/音色 | BSRAM 充裕；多相插值只需简单加权 |
| 单声部输出 | signed 24 bit（包络与力度运算中保留保护位） | 24 bit 是 A→C 的冻结位宽 |
| 混音累加器 | signed **28 bit**（留 4 位余量） | 32 路 24 bit 相加最大需要 24+5=29 bit，取 28 bit 需**先分级缩放**；实现时按 4 路一组先右移 2 位 |
| 混音输出 | signed 24 bit + **饱和** | 宁可失真不可回绕（回绕 = 极性反转 = 爆音） |
| 采样率 | **48 kHz**，对外申报一律用此值 | 吞吐量指标按此计算，**过采样不加分** |
| I2S 输出 | 走**板载 DAC**，`HP_BCK`/`HP_WS`/`HP_DIN`；官方例程将 `PA_EN` 固定低电平常开 | 管脚已核实，见 `constraint/tang_mega138k.cst` |
| I2S 位宽 | 目标 **32 bit 槽 / 24 bit 数据**（BCK=3.072 MHz）；**板载 DAC 是否接受待实测**，不通则退回 16 bit 槽 | 见 [`C_官方例程与板载音频通路分析.md`](C_官方例程与板载音频通路分析.md) 的验证阶梯 |
| 总音量 | 16 bit 无符号，乘法后右移 16 | 便于参数直接映射 |

> ⚠️ **混音位宽是新手最容易踩的坑**：32 路 24 bit 累加会溢出到 29 bit。必须在加法树中**分级右移**或使用 28 位以上累加器 + 输出饱和，否则大和弦会出现"声音突然变刺/变小"的周期性失真。

---

## 6. 复位与节拍约定

| 项 | 约定 |
|---|---|
| 复位 | `rst_n` 低有效，由 `rtl/common/reset_sync.v` 产生（异步置位、同步释放） |
| 复位值 | 所有寄存器输出为 0；**音频输出必须为数值 0（静音）**，不得为随机/直流偏移 |
| `sample_tick` | 单拍脉冲，频率 48 kHz，由音频域 12.288 MHz / 256 产出，**抖动为 0** |
| 状态更新时机 | A 的音频状态只在 `sample_tick` 或明确握手点更新；**禁止依赖异步组合输入** |
| 上电顺序 | `audio_locked` → `engine_ready` → `input_ready` → `system_ready` |

---

## 7. 阶段 0 验收清单（本项目放行条件）

| # | 检查项 | 通过门槛 | 责任人 | 证据路径 |
|---|---|---|---|---|
| 1 | 三个 Gowin 工程可打开 | `audio_core_sim.gprj`、`input_ui_sim.gprj`、`audio_system_sim.gprj`、`synth_top.gprj` 无缺失文件 | A/B/C | — |
| 2 | 三个 testbench 可运行 | `tb_audio_core`、`tb_input`、`tb_system` 均能启动并结束，且各自有 PASS 判据 | A/B/C | `evidence/stage0/` |
| 3 | 接口冻结 | 第 1~4 节字段全部确认，A/B/C 无未决字段 | 全员 | 本文件 |
| 4 | 平台信息 | 器件型号、时钟、I2S 方案、管脚来源可解释 | C | `docs/PLATFORM_*.md` |
| 5 | 代码边界 | 三人无需修改他人目录即可开工 | 全员 | 目录结构 |
| 6 | 器件版本确认 | 已核对实物丝印并写入 `.cst` 注释 | C | `constraint/tang_mega138k.cst` |

**通过后打的标签**：`stage0-freeze`
**冻结物**：`event_defs.vh`、`status_defs.vh`、三个工程与 testbench 骨架、`.cst/.sdc` 初版、接口变更流程。

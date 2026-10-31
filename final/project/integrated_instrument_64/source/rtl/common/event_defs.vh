`timescale 1ns/1ps
//=============================================================================
// event_defs.vh —— 演奏事件 / 表情参数 / 音频输出 的唯一契约
//
// 归属：成员 C 维护（rtl/common/），A 与 B 共同使用。
//       任何字段的新增、删除、位宽或编码变更，必须：
//         1) 在本文件顶部 EVENTS_DEFS_VERSION 加 1；
//         2) 提交接口变更说明，通知 A 与 B；
//         3) 同步更新 tb_audio_core.v 与 tb_input.v。
//
// 状态：蓝图级冻结 —— 字段/位宽已定，A/B 可据此写 RTL 与 testbench。
//       阶段 0 验收会议确认后标记为正式冻结，此后只允许向后兼容的扩展。
//=============================================================================

`ifndef EVENT_DEFS_VH
`define EVENT_DEFS_VH

`define EVENTS_DEFS_VERSION     8'd2

//-----------------------------------------------------------------------------
// 1. 采样与时钟（来自平台冻结卡 docs/PLATFORM_TANG_MEGA_138K.md）
//    例化时请显式传参覆盖，以下仅作为默认值。
//-----------------------------------------------------------------------------
`define AUDIO_SAMPLE_RATE       48000           // Hz，实际输出采样率
`define AUDIO_BIT_DEPTH         24              // 有效音频位宽
`define I2S_SLOT_BITS           32              // 每声道槽位（BCK = 64 x LRCK）
`define I2S_CHANNELS            2
`define I2S_BCK_RATIO           64              // BCK = 64 x LRCK

// 主时钟示例：clk_fsys = 100 MHz 时，一个采样周期 = 2083 clk + 1/3 clk，
// 因此 sample_tick 必须用小数累加（Bresenham）方式生成，不能用固定分频。
// 若改用 4x 过采样支路的 clk_fs = 12.288 MHz，则每采样 256 clk，可整除。
`define CLK_FSYS_HZ             100_000_000
`define CLK_FS_HZ               12_288_000      // 48 kHz x 256

//-----------------------------------------------------------------------------
// 2. 相位累加器与音高精度（A 的振荡器设计依据）
//    32 位累加器 @48 kHz 时，频率分辨率 = 48000 / 2^32 = 1.1176e-5 Hz。
//    最低音 A0 = 27.5 Hz 时的最差音高误差约 0.0007 音分，可忽略。
//    波表地址取相位累加器的高 WAVETABLE_ADDR_BITS 位。
//-----------------------------------------------------------------------------
`define PHASE_ACC_BITS          32
`define WAVETABLE_ADDR_BITS     12              // 4096 点，可按音色调整

//-----------------------------------------------------------------------------
// 3. B -> A：演奏事件
//-----------------------------------------------------------------------------
`define EVENT_TYPE_BITS         2
`define NOTE_ID_BITS            7
`define VELOCITY_BITS           8

`define EVENT_NONE              2'd0
`define EVENT_NOTE_ON           2'd1
`define EVENT_NOTE_OFF          2'd2
`define EVENT_PARAM_CHANGE      2'd3

// 事件握手：event_valid 与其余字段同拍有效，保持 1 拍后撤销。
// 消费者 A 不需要 backpressure；A 每个 sample_tick 至少能吸收 1 个事件。
// 若 B 可能在同一拍产生多个事件，必须自行排队，RTL 中不得丢失事件。

// 音符号编码：标准 MIDI 音符号。A4 = 440 Hz 对应 note_id = 69。
// 建议键盘映射范围 note_id 36（C2）~ 84（C6）；其余值保留扩展。
// A 必须在 note_to_fc 中验证音高误差，目标 < 0.5 音分。

// 力度：0 视为无效/静音，1..127 有效。A 可在内部映射到增益曲线。

//-----------------------------------------------------------------------------
// 4. B -> A：连续表情参数
//-----------------------------------------------------------------------------
`define PARAM_ID_BITS           4
`define PARAM_VALUE_BITS        16

`define PARAM_VOLUME            4'd0    // 0x0000..0xFFFF，线性总音量
`define PARAM_INSTRUMENT        4'd1    // 低 4 位为音色索引
`define PARAM_PITCH_BEND        4'd2    // signed，-8192..+8191 约 ±2 半音
`define PARAM_MODULATION        4'd3    // 0x0000..0xFFFF，颤音深度
`define PARAM_FILTER            4'd4    // 0x0000..0xFFFF，滤波器/亮度
`define PARAM_EFFECT_MIX        4'd5    // 0x0000..0xFFFF，干湿比
`define PARAM_GLIDE             4'd6    // 0x0000..0xFFFF，滑音时间
`define PARAM_ATTACK            4'd7    // 预留
`define PARAM_DECAY             4'd8    // 预留
`define PARAM_SUSTAIN           4'd9    // 预留
`define PARAM_RELEASE           4'd10   // 预留
`define PARAM_TUNING            4'd11   // 预留，全局微调
// 4'd12 ~ 4'd15 保留

// param_id 不得承载音符事件；音符一律走 EVENT_NOTE_ON / EVENT_NOTE_OFF。

// Queue status extension (EVENTS_DEFS_VERSION = 2):
// event_overflow / param_overflow are sticky, high-active, reset-cleared.
`define EVENT_OVERFLOW_BITS     1
`define PARAM_OVERFLOW_BITS     1

//-----------------------------------------------------------------------------
// 5. A -> C：音频采样与状态
//-----------------------------------------------------------------------------
`define AUDIO_SAMPLE_BITS       24
`define AUDIO_WIDTH             24

// audio_left / audio_right 为有符号 24 位二进制补码，满量程约 ±8388607。
// audio_core_valid 与采样数据同拍有效，频率 = sample_tick 频率（48 kHz）。
// C 侧不得直接截断位宽；如需降低位宽，必须先饱和再移位。

`define ACTIVE_VOICE_CNT_BITS  6
`define MAX_VOICE_COUNT         48      // 计数饱和值，实际目标 >= 32

// 振荡器 / 通道计数口径（评分依据，务必按此声明）：
//   独立发声单元 = 独立相位累加器 + 独立频率调控 + 独立包络控制的完整振荡器
//   波表采样查表：  只计 1 个振荡器
//   加法合成：      按运算分量统计
//   FM：            按调制运算器统计
//   物理建模：      按并行弦 / 模态单元统计
//   吞吐量指标 = 同时活跃可闻独立振荡器总数 x 实际音频输出采样率(48 kHz)
//   过采样不叠加加分 —— 对外申报一律用 48 kHz 口径。

//-----------------------------------------------------------------------------
// 6. 控制信号（C -> A/B）
//-----------------------------------------------------------------------------
`define CTRL_STATUS_BITS        8

// system_ready / engine_ready / input_ready / audio_locked / i2s_active
// 均为电平信号、高有效；复位期间必须为 0。

`endif // EVENT_DEFS_VH

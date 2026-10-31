//=============================================================================
// synth_top.v —— 系统顶层（阶段 1 版本）
//
// 归属：成员 C 独占维护。
//
// 当前阶段（1）的信号链：
//   50MHz 晶振 ─► PLL ─► clk_audio 12.28814MHz
//                            │
//                            ├─ sample_scheduler ─► sample_tick(48kHz) / bck_en
//                            │        │
//                            │        └─► tone_src ─► 400Hz 正弦 (24bit L/R)
//                            │                │
    //                            └──────────────┴─► i2s_tx_official ─► HP_BCK/HP_WS/HP_DIN
//                                                              │
//                                                    板载 DAC + 功放(PA_EN)
//                                                              │
//                                                        耳机口 / 扬声器
//
// 阶段 2 的替换点：
//   tone_src 换成成员 A 的 audio_core，事件来自成员 B 的 input_top。
//   本顶层的其余部分不动。
//
// 合规说明：本阶段的音频是**单音正弦调试信号**，用于验证输出链路；
//           最终作品的全部音频由演奏事件实时合成。
//=============================================================================
module synth_top (
    input  wire        i_clk_in,     // 板载 50 MHz 晶振（管脚 V22）
    input  wire        i_rst_n,      // S2 原始输入（按下为高，松开为低；管脚 F4）
    // I2S 到板载 DAC
    output wire        o_hp_bck,
    output wire        o_hp_ws,
    output wire        o_hp_din,
    output wire        o_pa_en,      // 板载功放使能；官方例程为低电平常开
    // 状态指示
    output wire        o_led,
    output wire        o_locked
);

    //------------------------------------------------------------
    // 时钟与复位
    //------------------------------------------------------------
    wire clk_audio, clk_sys, pll_locked, rst_n;
    wire board_rst_n;

    // 官方例程为 rst_n = !rst：S2 原始输入高电平时复位，松开后低电平运行。
    // 顶层端口名保留 i_rst_n 以兼容现有约束，但在这里恢复成运行有效电平。
    assign board_rst_n = ~i_rst_n;

    clock_gen #(
        .FCLKIN           ("50.0"),
        .USE_INTERNAL_OSC (0),
        .IDIV_SEL         (6'd2),       // ÷2：Fpfd = 25 MHz（19~81.25 合法）
        .MDIV_SEL         (7'd29),      // VCO = 50/2*29 = 725 MHz（650~1300 合法）
        .ODIV0_SEL        (7'd59),      // -> 12.28814 MHz 音频域（LRCK=48.0005k）
        .ODIV1_SEL        (7'd7)        // -> 103.571 MHz 系统域
    ) u_clock_gen (
        .i_clk_in     (i_clk_in),
        .i_rst_n      (board_rst_n),
        .o_clk_audio  (clk_audio),
        .o_clk_sys    (clk_sys),
        .o_pll_locked (pll_locked)
    );

    reset_sync #(.SYNC_STAGES(3)) u_reset_sync (
        .clk    (clk_audio),
        .arst_n (board_rst_n & pll_locked),
        .rst_n  (rst_n)
    );

    //------------------------------------------------------------
    // 采样节拍
    //------------------------------------------------------------
    wire sample_tick, bck, bck_en;

    sample_scheduler #(
        .CLK_DIV_BCK    (4),            // BCK = clk_audio/8 = 1.536 MHz（板载 DAC 为 16bit 槽）
        .CLK_DIV_SAMPLE (256)           // LRCK = clk_audio/256 = 48.0005 kHz
    ) u_scheduler (
        .clk_audio   (clk_audio),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .bck         (bck),
        .bck_en      (bck_en)
    );

    //------------------------------------------------------------
    // 音源（阶段 1 临时：400 Hz 正弦，便于无仪器时听辨）
    //------------------------------------------------------------
    wire signed [23:0] sample_l, sample_r;

    tone_src #(
        .PHASE_INC (35791394)           // 400 Hz @ 48 kHz
    ) u_tone_src (
        .clk_audio   (clk_audio),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .sample_l    (sample_l),
        .sample_r    (sample_r)
    );

    //------------------------------------------------------------
    // I2S 发送
    //------------------------------------------------------------
    wire frame_start;

    // 【2026-09-25 上板实测修正】板载 DAC 只认 16bit 槽（官方例程实测格式：
    // BCK=1.536MHz、每声道 16bit、32 BCK/帧）。此前 32bit 槽装 24bit 数据
    // 上板表现为"全是杂音、音量最大才勉强可闻"——DAC 截到了槽内低位段。
    // 现改为 16bit 槽，送 24bit 样本的高 16 位（幅度不变，丢低 8bit 精度）。
    i2s_tx_official u_i2s_tx (
        .clk_audio   (clk_audio),
        .rst_n       (rst_n),
        .bck_in      (bck),
        .bck_en      (bck_en),
        .sample_l    (sample_l[23:8]),
        .sample_r    (sample_r[23:8]),
        .frame_start (frame_start),
        .o_bck       (o_hp_bck),
        .o_ws        (o_hp_ws),
        .o_din       (o_hp_din)
    );

    //------------------------------------------------------------
    // 状态指示
    //------------------------------------------------------------
    // 官方可发声例程的 top.v 明确使用 PA_EN=0（注释为“PA常开”）。
    // 当前板载功放的实际有效电平以该例程为准，不能把 PLL 锁定状态直接送入此脚。
    assign o_pa_en  = 1'b0;

    // 心跳：clk_audio / 2^20 ≈ 11.7 Hz —— 快到人眼看是"半亮常亮"
    // 【固件标记 v3】16bit 槽 + 本标记：若烧录后 W21 仍是肉眼可分辨的慢闪，
    // 说明烧录未生效；若变成"微亮常亮"，说明新固件在跑。
    reg [22:0] hb;
    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) hb <= 23'd0;
        else        hb <= hb + 1'b1;
    end

    assign o_led    = hb[19];
    assign o_locked = pll_locked;

endmodule

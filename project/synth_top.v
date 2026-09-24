//=============================================================================
// synth_top.v —— 系统顶层（阶段 1 版本）
//
// 归属：成员 C 独占维护。
//
// 当前阶段（1）的信号链：
//   50MHz 晶振 ─► PLL ─► clk_audio 12.29167MHz
//                            │
//                            ├─ sample_scheduler ─► sample_tick(48kHz) / bck_en
//                            │        │
//                            │        └─► tone_src ─► 1kHz 正弦 (24bit L/R)
//                            │                │
//                            └────────────────┴─► i2s_tx ─► HP_BCK/HP_WS/HP_DIN
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
    input  wire        i_rst_n,      // S2 按键，低有效（管脚 F4，1.5V 域）
    // I2S 到板载 DAC
    output wire        o_hp_bck,
    output wire        o_hp_ws,
    output wire        o_hp_din,
    output wire        o_pa_en,      // 板载功放使能，高有效
    // 状态指示
    output wire        o_led,
    output wire        o_locked
);

    //------------------------------------------------------------
    // 时钟与复位
    //------------------------------------------------------------
    wire clk_audio, clk_sys, pll_locked, rst_n;

    clock_gen #(
        .FCLKIN           ("50.0"),
        .USE_INTERNAL_OSC (0),
        .MDIV_SEL         (7'd59),      // VCO = 50MHz * 59 = 2950 MHz
        .ODIV0_SEL        (7'd80),      // -> 12.29167 MHz 音频域
        .ODIV1_SEL        (7'd10)       // -> 295 MHz 系统域
    ) u_clock_gen (
        .i_clk_in     (i_clk_in),
        .i_rst_n      (i_rst_n),
        .o_clk_audio  (clk_audio),
        .o_clk_sys    (clk_sys),
        .o_pll_locked (pll_locked)
    );

    reset_sync #(.SYNC_STAGES(3)) u_reset_sync (
        .clk    (clk_audio),
        .arst_n (i_rst_n & pll_locked),
        .rst_n  (rst_n)
    );

    //------------------------------------------------------------
    // 采样节拍
    //------------------------------------------------------------
    wire sample_tick, bck, bck_en;

    sample_scheduler #(
        .CLK_DIV_BCK    (2),            // BCK = clk_audio/4 = 3.072 MHz
        .CLK_DIV_SAMPLE (256)           // LRCK = clk_audio/256 = 48.015 kHz
    ) u_scheduler (
        .clk_audio   (clk_audio),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .bck         (bck),
        .bck_en      (bck_en)
    );

    //------------------------------------------------------------
    // 音源（阶段 1 临时：1 kHz 正弦）
    //------------------------------------------------------------
    wire signed [23:0] sample_l, sample_r;

    tone_src #(
        .PHASE_INC (89478485)           // 1 kHz @ 48 kHz
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

    i2s_tx #(
        .DATA_BITS (24),
        .SLOT_BITS (32),
        .WS_LEAD   (1)
    ) u_i2s_tx (
        .clk_audio   (clk_audio),
        .rst_n       (rst_n),
        .bck_en      (bck_en),
        .sample_l    (sample_l),
        .sample_r    (sample_r),
        .frame_start (frame_start),
        .o_bck       (o_hp_bck),
        .o_ws        (o_hp_ws),
        .o_din       (o_hp_din)
    );

    //------------------------------------------------------------
    // 状态指示
    //------------------------------------------------------------
    assign o_pa_en  = pll_locked;

    // 心跳：clk_audio / 2^23 ≈ 1.47 Hz
    reg [22:0] hb;
    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) hb <= 23'd0;
        else        hb <= hb + 1'b1;
    end

    assign o_led    = hb[22];
    assign o_locked = pll_locked;

endmodule

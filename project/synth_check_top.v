//=============================================================================
// synth_check_top.v —— 综合检查用顶层（不属于最终设计）
//
// 目的：把 clock_gen / reset_sync / sample_scheduler 接成完整信号链并综合，
//       验证语法可综合、时钟约束可满足、资源占用合理。
//
// 仿真请用 tb_scheduler（对 sample_scheduler 单独验证）；
// clock_gen 含厂商原语，需要厂商仿真库才能仿真。
//=============================================================================
module synth_check_top (
    input  wire i_clk_in,      // 50 MHz 外部参考
    input  wire i_rst_n,       // 低有效复位
    output wire o_hp_bck,      // 位时钟
    output wire o_hp_ws,       // 声道选择（低 = 左声道）
    output wire o_hp_din,      // 数据
    output wire o_pa_en,       // 功放使能（高有效）
    output wire o_led,         // 心跳指示
    output wire o_locked       // PLL 锁定指示
);

    wire clk_audio, clk_sys, pll_locked, rst_n;

    clock_gen #(
        .FCLKIN           ("50.0"),
        .USE_INTERNAL_OSC (0),
        .IDIV_SEL         (6'd0),       // 硬件 1
        .FBDIV_SEL        (6'd0),       // 硬件 1
        .MDIV_SEL         (7'd58),      // 硬件 59  -> VCO 983.333 MHz
        .ODIV0_SEL        (7'd80),      // 硬件 80  -> 12.29167 MHz
        .ODIV1_SEL        (7'd10)       // 硬件 10  -> 98.333 MHz
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

    wire sample_tick, bck, bck_en;

    sample_scheduler #(
        .CLK_DIV_BCK    (4),
        .CLK_DIV_SAMPLE (256)
    ) u_scheduler (
        .clk_audio   (clk_audio),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .bck         (bck),
        .bck_en      (bck_en)
    );

    // ---- 阶段 1 的临时输出（i2s_tx 完成后由它接管）----
    assign o_hp_bck = bck;
    assign o_hp_ws  = bck_en ? ~bck : bck;
    assign o_hp_din = sample_tick;
    assign o_pa_en  = pll_locked;
    assign o_locked = pll_locked;

    // 心跳指示：clk_audio / 2^24 ≈ 0.73 Hz
    reg [23:0] hb;
    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) hb <= 24'd0;
        else        hb <= hb + 1'b1;
    end
    assign o_led = hb[23];             // 心跳 ≈ 0.73 Hz

endmodule

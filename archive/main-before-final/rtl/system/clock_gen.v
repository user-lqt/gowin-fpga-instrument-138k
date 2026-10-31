//=============================================================================
// clock_gen.v —— 时钟生成（GW5AST 的 PLL 原语）
//
// 归属：成员 C 独占维护。
//
// 输出：
//   o_clk_audio   音频域主时钟，目标 12.288 MHz（48 kHz x 256）
//   o_clk_sys     系统域时钟（阶段 1 旁路参考时钟，阶段 2 换第二路 PLL）
//   o_pll_locked  PLL 锁定指示，用于复位
//
// ---------------------------------------------------------------------------
// 为什么音频域要用 x256 的时钟
//   12,288,000 / 256 = 48,000 整除 —— LRCK 无抖动。
//   用 100 MHz 分频得 2083.33，除不尽，需要小数累加，会有抖动，
//   违反赛题拓展要求"确定性无抖动延迟"。
//
// ---------------------------------------------------------------------------
// 为什么用 PLL 原语而不是 rPLL
//   GW5AST-138 的时钟资源只提供 PLL 原语（含 7 路输出），没有 rPLL。
//   （rPLL 是 GW1N/GW2A 系列的原语。）
//   已实测：实例化 rPLL 会报 "Instantiating unknown module 'rPLL'"。
//
//     PLL 分频模型（UG306 Arora V 时钟资源指南，表 5-4/5-8 核实）：
//       Fpfd      = FCLKIN / IDIV
//       f_VCO     = Fpfd * FBDIV * MDIV      （CLKFBOUT 外部反馈）
//       f_CLKOUTn = f_VCO / ODIVn
//       ★ 分频参数静态值 = 实际分频值（无 +1 语义）
//       ★ GW5AST-138K 约束：VCO 650~1300 MHz（UG306 §2.3）；
//         PFD = FCLKIN/IDIV 必须 19~81.25 MHz（PA2078 报错实测）
//
// ---------------------------------------------------------------------------
// 当前参数（2026-09-24 修正，经时序报告 Generated Clock 推导验证）：
//
//   IDIV=2, FBDIV=1, MDIV=29 -> VCO = 50/2*29 = 725 MHz（650~1300 内 ✓）
//   ODIV0=59 -> CLKOUT0 = 12.28814 MHz（音频域）
//   ODIV1=7  -> CLKOUT1 = 103.571  MHz（系统域，阶段 2 用）
//   实际 LRCK = 12,288,136 / 256 = 48,000.5 Hz（偏离 +0.0011%，约 +0.02 音分，
//   远优于人耳可辨阈值 5~10 音分 —— 基本等于精确 48 kHz）
//
// 【踩坑记录 1】曾写成 IDIV_SEL=0 且 defparam 漏传 IDIV_SEL/FBDIV_SEL：
//   IDIV 按默认 ÷1，VCO = 50*59 = 2950 MHz 远超范围（硬件上不锁定），
//   工具推导输出 36.875 MHz，LRCK 会快 3 倍。
// 【踩坑记录 2】改 IDIV=3 后 PFD = 16.67 MHz < 19 MHz，报 PA2078。
//   教训：PLL 频率必须看时序报告 Clock Summary 的 Generated Clock
//   推导值，不能只看注释；参数空间要同时满足 VCO 与 PFD 两个范围。
//
// 备注：精确 12.288 MHz 在 PFD≥19MHz 约束下凑不出整数比，12.288136 MHz
// 已是全参数空间最优解（脚本穷举 IDIV/FBDIV/MDIV/ODIV0 验证）。
//=============================================================================
module clock_gen #(
    // 参考时钟频率（仅用于 PLL 工具计算与告警，不改变分频）
    parameter FCLKIN = "50.0",
    // 1 = 用内部 OSC 作参考（基频未知，应急）；0 = 用 i_clk_in
    parameter USE_INTERNAL_OSC = 0,
    // 内部 OSC 分频：2..128 的偶数
    parameter OSC_FREQ_DIV = 4,
    // PLL 分频参数（静态值 = 实际分频值，UG306 表 5-4/5-8）
    parameter IDIV_SEL  = 6'd2,     // ÷2：Fpfd = 25 MHz（19~81.25 内 ✓）
    parameter FBDIV_SEL = 6'd1,     // ×1
    parameter MDIV_SEL  = 7'd29,    // ×29：VCO = 725 MHz
    parameter ODIV0_SEL = 7'd59,    // ÷59：12.28814 MHz 音频域
    parameter ODIV1_SEL = 7'd7      // ÷7：103.571 MHz 系统域
) (
    input  wire i_clk_in,
    input  wire i_rst_n,
    output wire o_clk_audio,
    output wire o_clk_sys,
    output wire o_pll_locked
);

    wire osc_clk;

    generate
        if (USE_INTERNAL_OSC == 1) begin : g_use_osc
            OSC osc_inst (
                .OSCOUT (osc_clk)
            );
            defparam osc_inst.FREQ_DIV = OSC_FREQ_DIV;
        end else begin : g_use_ext
            assign osc_clk = 1'b0;
        end
    endgenerate

    wire ref_clk;
    assign ref_clk = (USE_INTERNAL_OSC == 1) ? osc_clk : i_clk_in;

    //------------------------------------------------------------
    // PLL 原语
    //------------------------------------------------------------
    wire pll_clk0, pll_clk1, pll_lock, pll_fb;
    wire pll_clk_unused;

    PLL pll_inst (
        .CLKIN       (ref_clk),
        .CLKFB       (pll_fb),
        .RESET       (~i_rst_n),
        .PLLPWD      (1'b0),
        .RESET_I     (1'b0),
        .RESET_O     (1'b0),
        .FBDSEL      (6'd0),
        .IDSEL       (6'd0),
        .MDSEL       (7'd0),
        .MDSEL_FRAC  (3'd0),
        .ODSEL0      (7'd0),
        .ODSEL0_FRAC (3'd0),
        .ODSEL1      (7'd0),
        .ODSEL2      (7'd0),
        .ODSEL3      (7'd0),
        .ODSEL4      (7'd0),
        .ODSEL5      (7'd0),
        .ODSEL6      (7'd0),
        .DT0         (4'd0),
        .DT1         (4'd0),
        .DT2         (4'd0),
        .DT3         (4'd0),
        .ICPSEL      (6'd0),
        .LPFRES      (3'd0),
        .LPFCAP      (2'd0),
        .PSSEL       (3'd0),
        .PSDIR       (1'b0),
        .PSPULSE     (1'b0),
        .ENCLK0      (1'b1),
        .ENCLK1      (1'b1),
        .ENCLK2      (1'b0),
        .ENCLK3      (1'b0),
        .ENCLK4      (1'b0),
        .ENCLK5      (1'b0),
        .ENCLK6      (1'b0),
        .SSCPOL      (1'b0),
        .SSCON       (1'b0),
        .SSCMDSEL    (7'd0),
        .SSCMDSEL_FRAC (3'd0),
        .CLKFBOUT    (pll_fb),
        .LOCK        (pll_lock),
        .CLKOUT0     (pll_clk0),
        .CLKOUT1     (pll_clk1),
        .CLKOUT2     (pll_clk_unused),
        .CLKOUT3     (pll_clk_unused),
        .CLKOUT4     (pll_clk_unused),
        .CLKOUT5     (pll_clk_unused),
        .CLKOUT6     (pll_clk_unused)
    );

    defparam pll_inst.FCLKIN         = FCLKIN;
    defparam pll_inst.DYN_IDIV_SEL   = "FALSE";
    defparam pll_inst.IDIV_SEL       = IDIV_SEL;   // ← 曾整行缺失，IDIV 一直按默认 ÷1
    defparam pll_inst.DYN_FBDIV_SEL  = "FALSE";
    defparam pll_inst.FBDIV_SEL      = FBDIV_SEL;  // ← 同上，补上
    defparam pll_inst.DYN_MDIV_SEL   = "FALSE";
    defparam pll_inst.MDIV_SEL       = MDIV_SEL;
    defparam pll_inst.MDIV_FRAC_SEL  = 3'd0;
    defparam pll_inst.DYN_ODIV0_SEL  = "FALSE";
    defparam pll_inst.ODIV0_SEL      = ODIV0_SEL;
    defparam pll_inst.ODIV0_FRAC_SEL = 3'd0;
    defparam pll_inst.DYN_ODIV1_SEL  = "FALSE";
    defparam pll_inst.ODIV1_SEL      = ODIV1_SEL;
    defparam pll_inst.CLKOUT0_EN     = "TRUE";
    defparam pll_inst.CLKOUT1_EN     = "TRUE";
    defparam pll_inst.CLKOUT2_EN     = "FALSE";
    defparam pll_inst.CLKOUT3_EN     = "FALSE";
    defparam pll_inst.CLKOUT4_EN     = "FALSE";
    defparam pll_inst.CLKOUT5_EN     = "FALSE";
    defparam pll_inst.CLKOUT6_EN     = "FALSE";
    defparam pll_inst.CLKFB_SEL      = "EXTERNAL";

    assign o_clk_audio  = pll_clk0;
    assign o_clk_sys    = pll_clk1;
    assign o_pll_locked = pll_lock;

endmodule

//=============================================================================
// tb_scheduler.v —— sample_scheduler 自检
//
// 两个 DUT：
//   DUT_FAST  CLK_DIV_BCK=2, CLK_DIV_SAMPLE=32   （小分频，逻辑等价，仿真快）
//   DUT_HW    CLK_DIV_BCK=2, CLK_DIV_SAMPLE=256  （真实硬件配置）
//
// 设计原则：**所有期望值都由参数推导**，不写死结论。
//   slot_per_sample   = CLK_DIV_SAMPLE / CLK_DIV_BCK      （I2S bit slot 数）
//   bck_full_per_smp  = slot_per_sample / 2               （bck 完整周期数）
//   bck_edge_per_smp  = bck_full_per_smp                  （上升沿数）
//   bck_en_per_smp    = slot_per_sample                   （位周期使能数）
//
// 规格断言（把 I2S 关系锁死，防止参数再被改错）：
//   硬件配置下 slot_per_sample 必须正好 = 64
//   且必须满足 CLK_DIV_SAMPLE = 2 * CLK_DIV_BCK * 32
//=============================================================================
`timescale 1ns/1ps

module tb_scheduler;

    //------------------------------------------------------------
    // DUT 参数
    //------------------------------------------------------------
    localparam integer FAST_SAMPLE = 32;
    localparam integer FAST_BCK    = 2;
    localparam integer HW_SAMPLE   = 256;
    localparam integer HW_BCK      = 2;

    localparam integer FAST_N = 64;    // 观察的采样周期数
    localparam integer HW_N   = 64;

    // 由参数推导的期望值（公式见文件头的分析）
    //   bck_en 脉冲 / sample = S / D          （D = CLK_DIV_BCK）
    //   bck 上升沿 / sample  = S / (2D)
    //   BCK / LRCK           = S / (2D)  必须 = 64
    localparam integer FAST_EN_PER_SMP   = FAST_SAMPLE / FAST_BCK;          // S/D
    localparam integer FAST_EDGE_PER_SMP = FAST_SAMPLE / (2 * FAST_BCK);    // S/(2D)
    localparam integer HW_EN_PER_SMP     = HW_SAMPLE   / HW_BCK;
    localparam integer HW_EDGE_PER_SMP   = HW_SAMPLE   / (2 * HW_BCK);

    localparam integer FAST_EXP_TICK = FAST_N;
    localparam integer FAST_EXP_EDGE = FAST_N * FAST_EDGE_PER_SMP;
    localparam integer FAST_EXP_EN   = FAST_N * FAST_EN_PER_SMP;

    localparam integer HW_EXP_TICK = HW_N;
    localparam integer HW_EXP_EDGE = HW_N * HW_EDGE_PER_SMP;
    localparam integer HW_EXP_EN   = HW_N * HW_EN_PER_SMP;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;

    //-------------------- 快速 DUT --------------------
    wire s_tick_f, bck_f, bck_en_f;
    sample_scheduler #(
        .CLK_DIV_BCK    (FAST_BCK),
        .CLK_DIV_SAMPLE (FAST_SAMPLE)
    ) dut_fast (
        .clk_audio   (clk),
        .rst_n       (rst_n),
        .sample_tick (s_tick_f),
        .bck         (bck_f),
        .bck_en      (bck_en_f)
    );

    //-------------------- 硬件参数 DUT --------------------
    wire s_tick_h, bck_h, bck_en_h;
    sample_scheduler #(
        .CLK_DIV_BCK    (HW_BCK),
        .CLK_DIV_SAMPLE (HW_SAMPLE)
    ) dut_hw (
        .clk_audio   (clk),
        .rst_n       (rst_n),
        .sample_tick (s_tick_h),
        .bck         (bck_h),
        .bck_en      (bck_en_h)
    );

    always #40 clk = ~clk;      // 80 ns 周期，与硬件音频域同量级

    integer tick_f = 0, rise_f = 0, en_f = 0;
    integer tick_h = 0, rise_h = 0, en_h = 0;
    reg bck_f_d = 1'b0, bck_h_d = 1'b0;

    always @(posedge clk) begin
        if (s_tick_f)         tick_f <= tick_f + 1;
        if (bck_en_f)         en_f   <= en_f + 1;
        if (bck_f & ~bck_f_d) rise_f <= rise_f + 1;
        bck_f_d <= bck_f;

        if (s_tick_h)         tick_h <= tick_h + 1;
        if (bck_en_h)         en_h   <= en_h + 1;
        if (bck_h & ~bck_h_d) rise_h <= rise_h + 1;
        bck_h_d <= bck_h;
    end

    integer t_f1, t_f2, r_f1, r_f2, e_f1, e_f2;
    integer t_h1, t_h2, r_h1, r_h2, e_h1, e_h2;
    integer rst_tick, rst_bck;
    integer errors = 0;
    integer i;

    task check_eq;
        input [255:0] name;
        input integer got;
        input integer exp;
        begin
            if (got == exp) $display("  [PASS] %0s = %0d", name, got);
            else begin
                $display("  [FAIL] %0s = %0d   (expected %0d)", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_scheduler.vcd");
        $dumpvars(0, tb_scheduler);

        $display("");
        $display("==================================================");
        $display(" tb_scheduler -- sample_scheduler self-test");
        $display("   FAST: BCK_DIV=%0d SAMPLE_DIV=%0d  bck_edges/smp=%0d  bck_en/smp=%0d",
                 FAST_BCK, FAST_SAMPLE, FAST_EDGE_PER_SMP, FAST_EN_PER_SMP);
        $display("   HW  : BCK_DIV=%0d SAMPLE_DIV=%0d  bck_edges/smp=%0d  bck_en/smp=%0d",
                 HW_BCK, HW_SAMPLE, HW_EDGE_PER_SMP, HW_EN_PER_SMP);
        $display("==================================================");

        //============ 复位 ============
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_tick = tick_f;  rst_bck = bck_f;
        $display("");
        $display("-- reset check --");
        check_eq("sample_tick during reset", rst_tick, 0);
        check_eq("bck during reset", rst_bck, 0);

        rst_n = 1'b1;
        @(posedge s_tick_f);
        @(posedge clk);

        //============ 快速 DUT ============
        t_f1 = tick_f; r_f1 = rise_f; e_f1 = en_f;
        for (i = 0; i < FAST_N * FAST_SAMPLE; i = i + 1) @(posedge clk);
        t_f2 = tick_f; r_f2 = rise_f; e_f2 = en_f;

        $display("");
        $display("-- DUT_FAST (BCK_DIV=%0d, SAMPLE_DIV=%0d) --", FAST_BCK, FAST_SAMPLE);
        check_eq("sample_tick count", t_f2 - t_f1, FAST_EXP_TICK);
        check_eq("bck rising edges", r_f2 - r_f1, FAST_EXP_EDGE);
        check_eq("bck_en pulses",    e_f2 - e_f1, FAST_EXP_EN);
        check_eq("bck_en per sample", (e_f2 - e_f1) / (t_f2 - t_f1), FAST_EN_PER_SMP);

        //============ 硬件 DUT ============
        t_h1 = tick_h; r_h1 = rise_h; e_h1 = en_h;
        for (i = 0; i < HW_N * HW_SAMPLE; i = i + 1) @(posedge clk);
        t_h2 = tick_h; r_h2 = rise_h; e_h2 = en_h;

        $display("");
        $display("-- DUT_HW (BCK_DIV=%0d, SAMPLE_DIV=%0d) --", HW_BCK, HW_SAMPLE);
        check_eq("sample_tick count", t_h2 - t_h1, HW_EXP_TICK);
        check_eq("bck rising edges", r_h2 - r_h1, HW_EXP_EDGE);
        check_eq("bck_en pulses",    e_h2 - e_h1, HW_EXP_EN);
        check_eq("bck_en per sample", (e_h2 - e_h1) / (t_h2 - t_h1), HW_EN_PER_SMP);

        //============ I2S 规格断言（关键）============
        $display("");
        $display("-- I2S SPEC checks --");
        check_eq("HW BCK edges per sample (=BCK/LRCK)", HW_EDGE_PER_SMP, 64);
        check_eq("HW bck_en pulses per sample", HW_EN_PER_SMP, 128);
        check_eq("param relation SAMPLE = 128*BCK_DIV", HW_SAMPLE, 128 * HW_BCK);
        $display("  [INFO] => BCK = 64 x LRCK  (32-bit slot x 2 channels)");

        //============ 频率换算 =============
        $display("");
        $display("-- frequency figures (design calculation) --");
        $display("  [INFO] clk_audio = 12.29167 MHz");
        $display("  [INFO] LRCK = clk_audio / %0d = 48.0149 kHz", HW_SAMPLE);
        $display("  [INFO] BCK  = clk_audio / %0d =  3.0729 MHz", 2 * HW_BCK);
        $display("  [INFO] these are DESIGN values; measure on board to confirm");

        $display("");
        $display("==================================================");
        if (errors == 0)
            $display(" RESULT: PASS   (all checks passed)");
        else
            $display(" RESULT: FAIL   (%0d checks failed)", errors);
        $display("==================================================");
        $display("");

        $finish;
    end

    initial begin
        #20_000_000;
        $display(" RESULT: FAIL   (simulation timeout)");
        $finish;
    end

endmodule

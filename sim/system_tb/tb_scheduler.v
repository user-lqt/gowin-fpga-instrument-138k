//=============================================================================
// tb_scheduler.v —— sample_scheduler 自检 testbench
//
// 两个 DUT：
//   DUT_FAST  CLK_DIV_BCK=4, CLK_DIV_SAMPLE=32   （小分频，逻辑等价，仿真快）
//   DUT_HW    CLK_DIV_BCK=4, CLK_DIV_SAMPLE=256  （真实硬件配置）
//
// 设计原则：**期望值全部由参数推导**，不写死结论。
//
// 窗口起点用"等第一个 sample_tick 到来"对齐，避免 off-by-one 误差。
//
// 度量：
//   T = sample_tick 个数
//   R = bck 上升沿个数
//   E = bck_en 脉冲个数（= bck 半周期数）
// 期望：
//   T = 窗口内采样周期数
//   R = T * (CLK_DIV_SAMPLE / CLK_DIV_BCK) / 2     <- 每采样 bck 周期数的一半
//   E = T * (CLK_DIV_SAMPLE / CLK_DIV_BCK)         <- 每采样 bck 半周期数
//   => 关键比例  E / T = CLK_DIV_SAMPLE / CLK_DIV_BCK
//=============================================================================
`timescale 1ns/1ps

module tb_scheduler;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;

    //-------------------- 快速 DUT --------------------
    wire s_tick_f, bck_f, bck_en_f;
    sample_scheduler #(
        .CLK_DIV_BCK    (4),
        .CLK_DIV_SAMPLE (32)
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
        .CLK_DIV_BCK    (4),
        .CLK_DIV_SAMPLE (256)
    ) dut_hw (
        .clk_audio   (clk),
        .rst_n       (rst_n),
        .sample_tick (s_tick_h),
        .bck         (bck_h),
        .bck_en      (bck_en_h)
    );

    // 时钟周期 80ns（与硬件音频域同量级）
    always #40 clk = ~clk;

    //-------------------- 计数器（各自单一驱动源）--------------------
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

    // 期望值（由参数推导）
    localparam integer FAST_SAMPLE = 32;
    localparam integer FAST_BCK    = 4;
    localparam integer HW_SAMPLE   = 256;
    localparam integer HW_BCK      = 4;
    localparam integer FAST_N      = 64;    // 观察的采样周期数
    localparam integer HW_N        = 64;

    localparam integer FAST_EXP_T = FAST_N;
    localparam integer FAST_EXP_R = FAST_N * (FAST_SAMPLE / FAST_BCK) / 2;
    localparam integer FAST_EXP_E = FAST_N * (FAST_SAMPLE / FAST_BCK);

    localparam integer HW_EXP_T = HW_N;
    localparam integer HW_EXP_R = HW_N * (HW_SAMPLE / HW_BCK) / 2;
    localparam integer HW_EXP_E = HW_N * (HW_SAMPLE / HW_BCK);

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
        $display(" tb_scheduler  --  sample_scheduler self-test");
        $display("==================================================");

        //============ 复位检查 ============
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_tick = tick_f;  rst_bck = bck_f;
        $display("");
        $display("-- reset check --");
        check_eq("sample_tick during reset", rst_tick, 0);
        check_eq("bck during reset", rst_bck, 0);

        rst_n = 1'b1;

        // 等第一个采样节拍对齐窗口起点
        @(posedge s_tick_f);
        @(posedge clk);

        //============ 快速 DUT ============
        t_f1 = tick_f; r_f1 = rise_f; e_f1 = en_f;
        // 窗口 = FAST_N 个采样周期 = FAST_N * FAST_SAMPLE 拍
        for (i = 0; i < FAST_N * FAST_SAMPLE; i = i + 1) @(posedge clk);
        t_f2 = tick_f; r_f2 = rise_f; e_f2 = en_f;

        $display("");
        $display("-- DUT_FAST  (CLK_DIV_BCK=%0d, CLK_DIV_SAMPLE=%0d) --", FAST_BCK, FAST_SAMPLE);
        check_eq("sample_tick count", t_f2 - t_f1, FAST_EXP_T);
        check_eq("bck rising edges", r_f2 - r_f1, FAST_EXP_R);
        check_eq("bck_en pulses",    e_f2 - e_f1, FAST_EXP_E);
        check_eq("bck half-periods per sample", (e_f2 - e_f1) / (t_f2 - t_f1), FAST_SAMPLE / FAST_BCK);

        //============ 硬件 DUT ============
        t_h1 = tick_h; r_h1 = rise_h; e_h1 = en_h;
        for (i = 0; i < HW_N * HW_SAMPLE; i = i + 1) @(posedge clk);
        t_h2 = tick_h; r_h2 = rise_h; e_h2 = en_h;

        $display("");
        $display("-- DUT_HW  (CLK_DIV_BCK=%0d, CLK_DIV_SAMPLE=%0d) --", HW_BCK, HW_SAMPLE);
        check_eq("sample_tick count", t_h2 - t_h1, HW_EXP_T);
        check_eq("bck rising edges", r_h2 - r_h1, HW_EXP_R);
        check_eq("bck_en pulses",    e_h2 - e_h1, HW_EXP_E);
        check_eq("bck half-periods per sample", (e_h2 - e_h1) / (t_h2 - t_h1), HW_SAMPLE / HW_BCK);

        //============ I2S 关键关系 ============
        $display("");
        $display("-- I2S ratio (BCK = 64 x LRCK) --");
        check_eq("HW: bck half-periods per sample", HW_SAMPLE / HW_BCK, 64);
        check_eq("HW: bck periods per sample", (HW_SAMPLE / HW_BCK) / 2, 32);

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

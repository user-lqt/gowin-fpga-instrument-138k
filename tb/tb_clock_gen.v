//=============================================================================
// tb_clock_gen.v —— 时钟链路自检
//
// 为什么需要这个 tb：
//   clock_gen 实例化厂商原语 PLL / OSC，需要厂商仿真库才能仿真，
//   因此真实实现无法直接用行为仿真验证。本 tb 的做法：
//     1) 用**行为模型**取代厂商 PLL，公式与 RTL 参数一致
//     2) 用 SCALE 放大周期以压缩仿真时间（比值保持不变）
//     3) 在足够长的窗口内做「周期计数」，反推 BCK / LRCK 周期与比值
//
// 踩过的两个坑（已修正，记录避免重复）：
//   坑1 用 `for(i=0;i<2000;i++) @(posedge bck);` 数边沿。
//       ModelSim ASE 处理带 $time 的边沿开销极大，换算成**数小时**墙钟。
//       改为「一次窗口 + 计数器」后降到秒级。
//   坑2 整数除法 `localparam T = (T_REF*80)/59` 会向下取整（2169 -> 2169.49 被截断），
//       导致期望值本身就不准。改用 real 直接算。
//
// 能证明：I2S 分频关系 BCK = 64 x LRCK、复位释放时序
// 不能证明（必须上板）：厂商 PLL 是否锁定、实际频率、能否出声
//=============================================================================
`timescale 1ns/1ps

module tb_clock_gen;

    //------------------------------------------------------------
    // 行为模型参数（硬件值；仿真把周期放大 SCALE 倍，比值不变）
    //------------------------------------------------------------
    localparam integer SCALE = 40;
    localparam integer MDIV  = 59;
    localparam integer ODIV0 = 80;
    localparam integer ODIV1 = 10;

    localparam integer CLK_DIV_BCK    = 2;
    localparam integer CLK_DIV_SAMPLE = 256;

    // 用 real 常量，避免整数截断
    localparam real T_REF      = 40.0 * SCALE;                 // 1600.0 ns
    localparam real T_CLKOUT0  = T_REF * ODIV0 / MDIV;         // 2169.4915 ns
    localparam real T_CLKOUT1  = T_REF * ODIV1 / MDIV;         // 271.1864 ns

    // 测量窗口：必须明显大于一个 LRCK 周期（此处约 5 个 LRCK）
    localparam integer WIN = 10_000_000;    // 10 ms 模型时间

    reg i_clk_in = 1'b0;
    reg i_rst_n  = 1'b0;
    always #(T_REF/2.0) i_clk_in = ~i_clk_in;

    //------------------------------------------------------------
    // 行为 PLL 模型
    //   时钟必须自由振荡；锁定只用于释放复位，不做时钟闸门，
    //   否则锁定前时钟不起振会导致仿真死锁。
    //------------------------------------------------------------
    reg clk_audio = 1'b0;
    reg clk_sys   = 1'b0;
    reg pll_locked = 1'b0;
    integer lock_cnt = 0;

    always @(posedge i_clk_in) begin
        if (!i_rst_n) begin
            lock_cnt   <= 0;
            pll_locked <= 1'b0;
        end else if (lock_cnt < 4) begin
            lock_cnt <= lock_cnt + 1;
        end else begin
            pll_locked <= 1'b1;
        end
    end

    always #(T_CLKOUT0/2.0) clk_audio = ~clk_audio;
    always #(T_CLKOUT1/2.0) clk_sys   = ~clk_sys;

    //------------------------------------------------------------
    // 被测：复位同步器 + 采样节拍
    //------------------------------------------------------------
    wire rst_n;
    reset_sync #(.SYNC_STAGES(3)) u_reset_sync (
        .clk    (clk_audio),
        .arst_n (i_rst_n & pll_locked),
        .rst_n  (rst_n)
    );

    wire sample_tick, bck, bck_en;
    sample_scheduler #(
        .CLK_DIV_BCK    (CLK_DIV_BCK),
        .CLK_DIV_SAMPLE (CLK_DIV_SAMPLE)
    ) u_scheduler (
        .clk_audio   (clk_audio),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .bck         (bck),
        .bck_en      (bck_en)
    );

    //------------------------------------------------------------
    // 周期计数（组合统计，几乎不增加事件开销）
    //------------------------------------------------------------
    integer cyc_bck  = 0;
    integer cyc_tick = 0;
    always @(posedge bck)         cyc_bck  = cyc_bck + 1;
    always @(posedge sample_tick) cyc_tick = cyc_tick + 1;

    integer errors = 0;
    integer snap_tick_prev = 0;
    integer snap_bck_prev  = 0;
    integer n_bck, n_tick;
    real    win_ps;              // 窗口长度（ns）
    real    t_bck_ns, t_lrck_ns;
    real    t_bck_exp, t_lrck_exp;
    real    ratio, ratio_exp;

    task check_near;
        input [255:0] name;
        input real    got;
        input real    exp;
        input real    rel_tol;
        begin
            if (exp > 0.0 && (got > exp*(1.0-rel_tol)) && (got < exp*(1.0+rel_tol)))
                $display("  [PASS] %0s = %0.4f ns  (expect %0.4f ns)", name, got, exp);
            else begin
                $display("  [FAIL] %0s = %0.4f ns  (expect %0.4f ns)", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_clock_gen.vcd");
        $dumpvars(0, tb_clock_gen);

        $display("");
        $display("==================================================");
        $display(" tb_clock_gen -- clock chain self-test");
        $display("   SCALE=%0d  T_REF=%0.3f ns", SCALE, T_REF);
        $display("   T_clkout0 = %0.4f ns", T_CLKOUT0);
        $display("   T_clkout1 = %0.4f ns", T_CLKOUT1);
        $display("==================================================");

        //============ 复位阶段 ============
        i_rst_n = 1'b0;
        repeat (20) @(posedge i_clk_in);
        $display("");
        $display("-- during reset --");
        if (bck === 1'b0 && sample_tick === 1'b0)
            $display("  [PASS] bck and sample_tick are both 0");
        else begin
            $display("  [FAIL] outputs not zero during reset");
            errors = errors + 1;
        end

        if (rst_n === 1'b0)
            $display("  [PASS] rst_n is 0 during reset");
        else begin
            $display("  [FAIL] rst_n is %b during reset", rst_n);
            errors = errors + 1;
        end

        //============ 释放并等锁定 ============
        i_rst_n = 1'b1;
        @(posedge rst_n);
        repeat (10) @(posedge clk_audio);

        $display("");
        $display("-- release --");
        $display("  [PASS] pll_locked=%b, rst_n released at t=%0t ns", pll_locked, $time);

        //============ 周期测量：等一个 tick 对齐窗口，再固定窗口计数 ============
        @(posedge sample_tick);
        @(negedge bck);
        snap_tick_prev = cyc_tick;
        snap_bck_prev  = cyc_bck;
        #WIN;
        n_tick = cyc_tick - snap_tick_prev;
        n_bck  = cyc_bck  - snap_bck_prev;

        win_ps = WIN * 1.0;

        if (n_bck > 0)  t_bck_ns  = win_ps / (n_bck  * 1.0);
        else            t_bck_ns  = -1.0;
        if (n_tick > 0) t_lrck_ns = win_ps / (n_tick * 1.0);
        else            t_lrck_ns = -1.0;

        // bck 每 CLK_DIV_BCK 拍翻转一次 -> 完整周期 = 2*CLK_DIV_BCK 拍
        t_bck_exp  = T_CLKOUT0 * CLK_DIV_BCK * 2.0;
        t_lrck_exp = T_CLKOUT0 * CLK_DIV_SAMPLE;

        $display("");
        $display("-- period measurement (window = %0d ns) --", WIN);
        $display("  [INFO] bck  rising edges in window = %0d", n_bck);
        $display("  [INFO] lrck rising edges in window = %0d", n_tick);
        check_near("BCK period",  t_bck_ns,  t_bck_exp,  0.02);
        check_near("LRCK period", t_lrck_ns, t_lrck_exp, 0.02);

        $display("");
        $display("-- ratio check: one I2S frame carries 64 bit slots --");
        ratio     = t_lrck_ns / t_bck_ns;
        ratio_exp = CLK_DIV_SAMPLE * 1.0 / (2.0 * CLK_DIV_BCK);
        if (ratio > (ratio_exp*0.98) && ratio < (ratio_exp*1.02))
            $display("  [PASS] LRCK / BCK = %0.3f  (expect %0.1f)", ratio, ratio_exp);
        else begin
            $display("  [FAIL] LRCK / BCK = %0.3f  (expect %0.1f)", ratio, ratio_exp);
            errors = errors + 1;
        end

        $display("");
        $display("-- hardware figures (design calculation) --");
        $display("  [INFO] clk_audio = 50MHz * 59 / 80       = 12.29167 MHz");
        $display("  [INFO] LRCK      = clk_audio / 256       = 48.0149 kHz -> 20826.9 ns");
        $display("  [INFO] BCK       = clk_audio / 4         =  3.0729 MHz ->  325.42 ns");
        $display("  [INFO] BCK / LRCK = 64   (32bit slot x 2ch, supports 24bit audio)");
        $display("  [INFO] +0.031%% off the ideal 48.000 kHz  (= +0.5 cent)");
        $display("  [INFO] design values only; real frequency MUST be measured");
        $display("  [INFO] on board with a scope / logic analyser.");

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
        #200_000_000;
        $display(" RESULT: FAIL   (simulation timeout at %0t)", $time);
        $finish;
    end

endmodule

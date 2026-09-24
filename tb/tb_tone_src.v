//=============================================================================
// tb_tone_src.v —— 临时音源冒烟测试
//
// 背景：tone_src 例化 sine_rom 时曾漏接 .clk（悬空高阻），导致输出恒为 x，
//       且该模块从未被仿真覆盖，bug 在代码检查时才被发现。
//       本 tb 锁死这条链路，防止同类问题回归。
//
// 检查项：
//   1) 复位后 sample_l/r 不再是 x
//   2) 连续若干个 sample_tick，sample 值确实在变化（正弦在走）
//   3) sample_l === sample_r（当前设计左右同源）
//   4) 幅值不超过 24bit 有符号范围（由 16bit 表左移 8 位得到，天然成立，
//      但 x/z 传播会破坏它，所以检查无 x/z）
//
// 【纪律】改完先改 TB_VERSION，确认输出里的版本号已更新再读结果。
//=============================================================================
`timescale 1ns/1ps

module tb_tone_src;

    localparam [255:0] TB_VERSION = "v1.0 2026-09-24 smoke test";

    reg clk_audio = 1'b0;
    reg rst_n     = 1'b0;
    always #5 clk_audio = ~clk_audio;      // 10 ns 周期

    // 采样节拍：与硬件一致，256 拍一个 tick
    wire sample_tick;
    wire bck, bck_en;
    sample_scheduler #(
        .CLK_DIV_BCK    (2),
        .CLK_DIV_SAMPLE (256)
    ) u_sched (
        .clk_audio   (clk_audio),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .bck         (bck),
        .bck_en      (bck_en)
    );

    wire signed [23:0] sample_l, sample_r;
    tone_src #(
        .PHASE_INC (89478485)           // 1 kHz @ 48 kHz
    ) u_tone (
        .clk_audio   (clk_audio),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .sample_l    (sample_l),
        .sample_r    (sample_r)
    );

    integer errors = 0;
    integer ticks  = 0;
    integer changes = 0;
    reg signed [23:0] prev;

    // 每个 sample_tick 检查一次输出
    always @(posedge clk_audio) begin
        if (rst_n && sample_tick) begin
            ticks = ticks + 1;
            if (^sample_l === 1'bx || ^sample_r === 1'bx) begin
                $display("  [FAIL] tick %0d: sample contains x/z (L=%h R=%h)",
                         ticks, sample_l, sample_r);
                errors = errors + 1;
            end
            if (sample_l !== sample_r) begin
                $display("  [FAIL] tick %0d: L(%0d) != R(%0d)", ticks, sample_l, sample_r);
                errors = errors + 1;
            end
            if (ticks > 1 && sample_l !== prev)
                changes = changes + 1;
            prev = sample_l;
        end
    end

    initial begin
        $display("");
        $display("==================================================");
        $display(" tb_tone_src  TB_VERSION: %0s", TB_VERSION);
        $display("==================================================");

        rst_n = 1'b0;
        repeat (20) @(posedge clk_audio);
        rst_n = 1'b1;

        // 跑 24 个 sample_tick（1 kHz 正弦 = 48 tick/周期，覆盖半个周期）
        wait (ticks >= 24);

        $display("-- smoke check --");
        if (ticks >= 24 && errors == 0)
            $display("  [PASS] %0d ticks, no x/z, L==R throughout", ticks);
        if (changes >= 20)
            $display("  [PASS] sample value is moving (%0d/%0d ticks changed)", changes, ticks-1);
        else begin
            $display("  [FAIL] sample value stuck (only %0d/%0d ticks changed)", changes, ticks-1);
            errors = errors + 1;
        end
        $display("  [INFO] last sample = %0d (0x%h)", sample_l, sample_l);

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
        #2_000_000;
        $display(" RESULT: FAIL   (simulation timeout at %0t ns)", $time);
        $finish;
    end

endmodule

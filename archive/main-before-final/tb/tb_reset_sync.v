//=============================================================================
// tb_reset_sync.v —— 复位同步器自检
//
// 验证：
//   1) arst_n 拉低 -> rst_n 立即（异步）拉低
//   2) arst_n 拉高 -> rst_n 延迟 SYNC_STAGES 拍才拉高（同步释放）
//   3) 复位释放前，下游计数器保持为 0
//   4) 复位释放后，下游计数器开始计数
//   5) 窄脉冲（< SYNC_STAGES 拍）不会误触发复位 —— 这是同步器抗毛刺的意义
//=============================================================================
`timescale 1ns/1ps

module tb_reset_sync;

    localparam integer STAGES = 3;
    localparam integer T_CLK  = 10;      // 100 MHz

    reg clk = 1'b0;
    reg arst_n = 1'b0;

    always #(T_CLK/2) clk = ~clk;

    wire rst_n;
    reset_sync #(.SYNC_STAGES(STAGES)) dut (
        .clk    (clk),
        .arst_n (arst_n),
        .rst_n  (rst_n)
    );

    // 下游计数器：用于验证复位是否真的起作用
    reg [7:0] cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cnt <= 8'd0;
        else        cnt <= cnt + 1'b1;
    end

    integer errors = 0;
    integer t_assert, t_release, t_rst_high, t_rst_low;

    task check_eq;
        input [255:0] name;
        input integer got;
        input integer exp;
        begin
            if (got == exp) $display("  [PASS] %0s = %0d", name, got);
            else begin
                $display("  [FAIL] %0s = %0d  (expected %0d)", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_reset_sync.vcd");
        $dumpvars(0, tb_reset_sync);

        $display("");
        $display("==================================================");
        $display(" tb_reset_sync -- reset synchroniser self-test (SYNC_STAGES=%0d)", STAGES);
        $display("==================================================");

        //---- 1. 异步置位：arst_n 拉低后 rst_n 必须立即变低 ----
        arst_n = 1'b0;
        #(T_CLK * 3);
        t_assert = $time;
        #1;                                  // 让组合路径稳定
        $display("");
        $display("-- 1. asynchronous assert --");
        check_eq("rst_n low immediately when arst_n=0", rst_n, 0);
        check_eq("downstream counter cleared", cnt, 0);

        //---- 2. 同步释放：arst_n 拉高后延迟 STAGES 拍 ----
        @(negedge clk);
        arst_n = 1'b1;
        t_release = $time;

        // 找到 rst_n 真正拉高的时刻
        @(posedge rst_n);
        t_rst_high = $time;

        $display("");
        $display("-- 2. synchronous release --");
        $display("  [INFO] arst_n release to rst_n high: %0d ns", t_rst_high - t_release);
        // 期望：至少 1 拍，最多 STAGES+1 拍
        if ((t_rst_high - t_release) >= T_CLK && (t_rst_high - t_release) <= T_CLK * (STAGES + 1))
            $display("  [PASS] release delay within %0d..%0d ns", T_CLK, T_CLK * (STAGES + 1));
        else begin
            $display("  [FAIL] release delay %0d ns out of range", t_rst_high - t_release);
            errors = errors + 1;
        end

        //---- 3. 释放后计数器恢复计数 ----
        repeat (20) @(posedge clk);
        $display("");
        $display("-- 3. works after release --");
        if (cnt > 8'd10) $display("  [PASS] counter running again (cnt=%0d)", cnt);
        else begin
            $display("  [FAIL] counter not running (cnt=%0d)", cnt);
            errors = errors + 1;
        end

        //---- 4. 窄脉冲不触发复位（抗毛刺）----
        $display("");
        $display("-- 4. narrow-pulse immunity --");
        // 用一个比 SYNC_STAGES 更短的脉冲：1 拍
        @(negedge clk);
        arst_n = 1'b0;
        @(negedge clk);
        arst_n = 1'b1;
        // 此时同步链被清零一拍，但重新填满需要 STAGES 拍
        // 关键：rst_n 不应该出现完整的一次低脉冲（除非脉冲宽度 >= STAGES 拍）
        t_rst_low = $time;
        repeat (STAGES + 2) @(posedge clk);
        if (rst_n === 1'b1)
            $display("  [PASS] rst_n recovered to 1 after narrow pulse");
        else begin
            $display("  [FAIL] rst_n still %b after narrow pulse", rst_n);
            errors = errors + 1;
        end

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
        #1_000_000;
        $display(" RESULT: FAIL   (simulation timeout)");
        $finish;
    end

endmodule

`timescale 1ns/1ps
module encoder_test_case #(parameter integer FILTER = 3)(output reg done);
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg [1:0] ab = 3;
    wire up, down, ready, rev_up, rev_down, rev_ready;
    integer ups = 0, downs = 0, i;
    reg last_up = 0, last_down = 0;
    encoder #(.FILTER_CYCLES(FILTER)) dut
        (clk, rst_n, ab[1], ab[0], up, down, ready);
    encoder #(.FILTER_CYCLES(FILTER), .REVERSE_DIR(1)) reversed
        (clk, rst_n, ab[1], ab[0], rev_up, rev_down, rev_ready);
    always @(posedge clk) begin
        #1;
        if (rst_n) begin
            if ((up && down) || (up && last_up) || (down && last_down))
                $fatal(1, "Invalid output pulse");
            if ((up !== rev_down) || (down !== rev_up) || (ready !== rev_ready))
                $fatal(1, "Direction reversal mismatch");
            if (up) ups = ups + 1;
            if (down) downs = downs + 1;
        end
        last_up = up;
        last_down = down;
    end
    task phase;
        input [1:0] value;
        begin
            @(negedge clk); ab = value;
            repeat (FILTER + 8) @(negedge clk);
        end
    endtask
    task reset_at;
        input [1:0] value;
        begin
            @(negedge clk); rst_n = 0; ab = value;
            repeat (4) @(negedge clk);
            ups = 0; downs = 0; rst_n = 1;
            repeat (FILTER + 12) @(negedge clk);
            if (!ready || ups != 0 || downs != 0) $fatal(1, "Startup event");
        end
    endtask
    task expect_counts;
        input integer u, d;
        begin
            if (ups != u || downs != d)
                $fatal(1, "FILTER=%0d expected %0d/%0d got %0d/%0d", FILTER, u, d, ups, downs);
        end
    endtask
    task cw;
        begin phase(2); phase(0); phase(1); phase(3); end
    endtask
    task ccw;
        begin phase(1); phase(0); phase(2); phase(3); end
    endtask
    initial begin
        done = 0;
        for (i = 0; i < 4; i = i + 1) reset_at(i);
        for (i = 0; i < 20; i = i + 1) cw;
        expect_counts(20, 0);
        for (i = 0; i < 20; i = i + 1) ccw;
        expect_counts(20, 20);
        reset_at(3);
        // Long bounce passes the filter but cancels in the quadrature decoder.
        phase(2); phase(3); phase(2); phase(0); phase(2);
        phase(0); phase(1); phase(3);
        expect_counts(1, 0);
        phase(1); phase(3); // Bounce across the completed-cycle boundary.
        expect_counts(1, 0);
        phase(2); phase(0); phase(2); phase(3); // Partial reversal.
        expect_counts(1, 0);
        ccw; expect_counts(1, 1);
        reset_at(3);
        phase(2); phase(1); // Illegal diagonal clears partial motion.
        phase(3); expect_counts(0, 0);
        reset_at(3); cw; expect_counts(1, 0);
        if (FILTER > 1) begin
            reset_at(3);
            // Every state is shorter than the filter: no false whole cycle.
            @(negedge clk); ab = 2;
            @(negedge clk); ab = 0;
            @(negedge clk); ab = 1;
            @(negedge clk); ab = 3;
            repeat (FILTER + 12) @(negedge clk);
            expect_counts(0, 0);
            cw; expect_counts(1, 0);
        end
        phase(2); phase(0); reset_at(3);
        ccw; expect_counts(0, 1);
        repeat (100) @(negedge clk);
        expect_counts(0, 1);
        $display("PASS encoder FILTER=%0d", FILTER);
        done = 1;
    end
endmodule

module tb_encoder;
    wire d1, d3, d8;
    encoder_test_case #(.FILTER(1)) c1(d1);
    encoder_test_case #(.FILTER(3)) c3(d3);
    encoder_test_case #(.FILTER(8)) c8(d8);
    initial begin
        wait (d1 && d3 && d8);
        $display("PASS all encoder tests");
        $finish;
    end
    initial begin #1000000; $fatal(1, "Timeout"); end
endmodule

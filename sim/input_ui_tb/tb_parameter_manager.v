`timescale 1ns/1ps
module parameter_test_case #(
    parameter [15:0] LIMIT = 127, DEFAULT_VALUE = 64, STEP = 1
)(output reg done);
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, up = 0, down = 0;
    wire [15:0] volume, value, ui;
    wire valid, dirty;
    wire [3:0] id;
    integer expected, old_value, i;
    reg expected_valid;
    parameter_manager #(.MAX_VOLUME(LIMIT), .DEFAULT_VOLUME(DEFAULT_VALUE),
        .VOLUME_STEP(STEP)) dut(clk, rst_n, up, down, volume, valid, id, value, ui, dirty, 1'b0, , );
    task check;
        reg [63:0] scaled;
        begin
            scaled = ({32'd0, expected} * 64'd65535 + LIMIT / 2) / LIMIT;
            if (volume !== expected || value !== scaled[15:0] || ui !== expected ||
                valid !== expected_valid || dirty !== expected_valid || id !== 4'h0)
                $fatal(1, "Volume mismatch limit=%0d expected=%0d got=%0d valid=%b", LIMIT, expected, volume, valid);
        end
    endtask
    task tick;
        input u, d;
        begin
            @(negedge clk); up = u; down = d;
            old_value = expected;
            if (u && !d) expected = expected + STEP;
            if (d && !u) expected = expected - STEP;
            if (expected < 0) expected = 0;
            if (expected > LIMIT) expected = LIMIT;
            expected_valid = (old_value != expected);
            @(posedge clk); #1; check;
        end
    endtask
    task restart;
        begin
            @(negedge clk); rst_n = 0; up = 0; down = 0;
            @(posedge clk); #1;
            expected = DEFAULT_VALUE; expected_valid = 0; check;
            @(negedge clk); rst_n = 1;
            @(posedge clk); #1; expected_valid = 1; check;
            tick(0, 0);
        end
    endtask
    initial begin
        done = 0;
        restart;
        tick(1, 1);
        for (i = 0; i < 140; i = i + 1) tick(1, 0);
        tick(1, 1); tick(0, 0);
        for (i = 0; i < 140; i = i + 1) tick(0, 1);
        tick(1, 1); tick(0, 0);
        for (i = 0; i < 20; i = i + 1) begin tick(1, 0); tick(0, 1); end
        restart;
        $display("PASS parameter manager limit=%0d step=%0d", LIMIT, STEP);
        done = 1;
    end
endmodule

module tb_parameter_manager;
    wire d1, d2, d3;
    parameter_test_case normal_case(d1);
    parameter_test_case #(.LIMIT(100), .DEFAULT_VALUE(98), .STEP(7)) clamp_case(d2);
    parameter_test_case #(.LIMIT(65535), .DEFAULT_VALUE(65530), .STEP(40000)) overflow_case(d3);
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg [1:0] ab = 3;
    wire ready, valid, dirty;
    wire [15:0] volume, value, ui;
    wire [3:0] id;
    integer events = 0;
    encoder_volume #(.FILTER_CYCLES(3)) integrated
        (clk, rst_n, ab[1], ab[0], ready, volume, valid, id, value, ui, dirty);
    always @(posedge clk) begin
        #1;
        if (rst_n && valid) events = events + 1;
    end
    task phase;
        input [1:0] state;
        begin @(negedge clk); ab = state; repeat (12) @(negedge clk); end
    endtask
    initial begin
        repeat (4) @(negedge clk); rst_n = 1;
        phase(3);
        if (!ready || volume != 64 || events != 1) $fatal(1, "Integration startup");
        phase(2); phase(0); phase(1); phase(3);
        if (volume != 65 || events != 2) $fatal(1, "Integration CW");
        phase(1); phase(0); phase(2); phase(3);
        if (volume != 64 || events != 3) $fatal(1, "Integration CCW");
        phase(2); phase(3);
        if (volume != 64 || events != 3) $fatal(1, "Integration bounce");
        wait (d1 && d2 && d3);
        $display("PASS parameter manager and encoder-volume integration");
        $finish;
    end
    initial begin #100000; $fatal(1, "Timeout"); end
endmodule

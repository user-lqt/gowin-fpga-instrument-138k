`timescale 1ns/1ps
`include "status_defs.vh"

module tb_system_status;
    reg clk_audio = 0;
    always #5 clk_audio = ~clk_audio;
    reg board_rst_n = 1'b0;
    reg audio_rst_n = 1'b0;
    reg pll_locked = 1'b0;
    reg sample_tick = 1'b0;
    reg frame_start = 1'b0;
    reg engine_ready = 1'b0;
    reg event_overflow = 1'b0;
    reg param_overflow = 1'b0;
    wire audio_locked;
    wire i2s_active;
    wire system_ready;
    wire [7:0] system_error;
    integer errors = 0;

    system_status dut (.*);

    task check;
        input condition;
        input [255:0] label;
        begin
            if (condition !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL %s", label);
            end else $display("PASS %s", label);
        end
    endtask

    initial begin
        #1;
        check(!audio_locked && !system_ready && system_error == 0, "reset state");
        board_rst_n = 1'b1;
        #1;
        check(system_error == `ERR_CLK_UNLOCKED && !system_ready, "PLL unlocked");
        pll_locked = 1'b1;
        audio_rst_n = 1'b1;
        engine_ready = 1'b1;
        #1;
        check(!audio_locked && !i2s_active && !system_ready,
              "engine ready alone cannot start B");
        @(negedge clk_audio);
        sample_tick = 1'b1;
        @(negedge clk_audio);
        sample_tick = 1'b0;
        check(!audio_locked && !system_ready, "sample alone cannot lock audio");
        frame_start = 1'b1;
        @(negedge clk_audio);
        frame_start = 1'b0;
        check(audio_locked && i2s_active && system_error == 0,
              "frame completes audio startup");
        #1;
        check(system_ready, "B may start before input_ready");
        param_overflow = 1'b1;
        #1;
        check(system_ready && system_error == `ERR_INPUT_QUEUE_OVERFLOW,
              "parameter overflow reports without stopping B");
        event_overflow = 1'b1;
        #1;
        check(!system_ready && system_error == `ERR_INPUT_QUEUE_OVERFLOW,
              "event overflow stops B");
        board_rst_n = 1'b0;
        audio_rst_n = 1'b0;
        #1;
        check(!audio_locked && !i2s_active && !system_ready && system_error == 0,
              "reset clears C status");
        if (errors) $fatal(1, "%0d system status checks failed", errors);
        $display("PASS system status checks");
        $finish;
    end
endmodule

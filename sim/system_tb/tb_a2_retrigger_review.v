`timescale 1ns/1ps
module tb_a2_retrigger_review;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, event_valid = 0;
    reg [7:0] divider = 0;
    always @(posedge clk) if (!rst_n) divider <= 0; else divider <= divider + 1'b1;
    wire tick = (divider == 255);
    wire valid, ready;
    wire signed [23:0] audio;
    wire [5:0] voices;
    integer before_sample, after_sample, jump, before_level, after_level;
    audio_core dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick),
        .event_valid(event_valid), .event_type(2'd1), .note_id(7'd69), .velocity(8'd127),
        .param_valid(1'b0), .param_id(4'd0), .param_value(16'd0),
        .audio_core_valid(valid), .audio_left(audio), .audio_right(),
        .active_voice_count(voices), .engine_ready(ready), .overload_flag(),
        .event_overflow(), .param_overflow()
    );
    task note_on;
        begin
            @(negedge clk); event_valid = 1;
            @(negedge clk); event_valid = 0;
        end
    endtask
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        wait (ready);
        note_on();
        repeat (3500) @(posedge valid);
        @(negedge clk);
        while (audio < 1300000) begin
            @(posedge valid); @(negedge clk);
        end
        before_sample = audio;
        before_level = dut.a2.envelope_levels[15:0];
        note_on();
        @(posedge valid); @(negedge clk);
        after_sample = audio;
        after_level = dut.a2.envelope_levels[15:0];
        jump = before_sample - after_sample;
        $display("RETRIGGER REVIEW before=%0d after=%0d jump=%0d envelope=%0d->%0d voices=%0d",
                 before_sample, after_sample, jump, before_level, after_level, voices);
        if (jump > 200000 || jump < -200000 || before_level != after_level || voices != 1)
            $fatal(1, "same-note retrigger introduced a waveform discontinuity");
        $display("PASS retrigger review: phase and envelope remain continuous");
        $finish;
    end
    initial begin
        #12000000;
        $fatal(1, "retrigger review timeout");
    end
endmodule

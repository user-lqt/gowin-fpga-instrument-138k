`timescale 1ns/1ps
module tb_audio_a2_probe_top;
    reg clk = 0;
    always #40.6901 clk = ~clk;
    reg reset_button = 1;
    wire bck, ws, din, pa_en, led, locked;
    integer events = 0, samples = 0, nonzero = 0, transitions = 0;
    reg signed [23:0] previous_sample = 0;

    audio_a2_probe_top dut (
        .i_clk_in(clk), .i_rst_n(reset_button),
        .o_hp_bck(bck), .o_hp_ws(ws), .o_hp_din(din),
        .o_pa_en(pa_en), .o_led(led), .o_locked(locked)
    );

    always @(posedge clk) begin
        if (dut.u_audio_core.event_valid) events = events + 1;
        if (dut.valid) begin
            samples = samples + 1;
            if (dut.audio_l != 0) nonzero = nonzero + 1;
            if (dut.audio_l != previous_sample) transitions = transitions + 1;
            previous_sample = dut.audio_l;
        end
    end

    initial begin
        repeat (5) @(negedge clk);
        reset_button = 0;
        wait (dut.engine_ready);
        repeat (1200) @(posedge dut.valid);
        if (events != 1 || dut.voice_count != 1 || nonzero < 1000 ||
            transitions < 1000 || dut.event_overflow || dut.param_overflow ||
            dut.overload || pa_en !== 1'b0 || !locked || led)
            $fatal(1, "probe did not sustain one clean A4 note");
        $display("PASS A2 probe: events=%0d samples=%0d nonzero=%0d transitions=%0d",
                 events, samples, nonzero, transitions);
        $finish;
    end

    initial begin
        #30000000;
        $fatal(1, "probe timeout");
    end
endmodule

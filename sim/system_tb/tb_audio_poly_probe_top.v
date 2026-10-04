`timescale 1ns/1ps
module tb_audio_poly_probe_top;
    reg clk = 0;
    always #40.6901 clk = ~clk;
    reg reset_button = 1;
    wire bck, ws, din, pa_en, led, locked;
    integer events = 0, samples = 0, nonzero = 0, clips = 0;
    integer gap = 0, serial_ones = 0;
    reg started = 0, previous_bck = 0;
    audio_poly_probe_top dut (
        .i_clk_in(clk), .i_rst_n(reset_button),
        .o_hp_bck(bck), .o_hp_ws(ws), .o_hp_din(din),
        .o_pa_en(pa_en), .o_led(led), .o_locked(locked)
    );
    always @(posedge clk) begin
        if (dut.event_valid) events = events + 1;
        if (!previous_bck && bck && din) serial_ones = serial_ones + 1;
        previous_bck = bck;
        if (started) begin
            gap = gap + 1;
            if (dut.valid) begin
                if (samples != 0 && gap != 256) $fatal(1, "sample cadence gap");
                gap = 0;
                samples = samples + 1;
                if (dut.audio_l != 0) nonzero = nonzero + 1;
                if (dut.overload) clips = clips + 1;
            end
        end
    end
    initial begin
        repeat (5) @(negedge clk);
        reset_button = 0;
        wait (dut.voice_count == 2);
        @(negedge clk); started = 1; gap = 0;
        repeat (6000) @(posedge dut.valid);
        @(negedge clk);
        $display("DYAD CHECK events=%0d voices=%0d volume=%0d nonzero=%0d clips=%0d serial=%0d",
                 events, dut.voice_count, dut.u_audio_core.volume,
                 nonzero, clips, serial_ones);
        if (events != 2 || dut.voice_count != 2 ||
            dut.u_audio_core.volume != 16'd33026 ||
            nonzero < 5500 || clips != 0 || serial_ones < 1000 ||
            dut.event_overflow || dut.param_overflow ||
            pa_en !== 1'b0 || !locked || led)
            $fatal(1, "fixed dyad produced bad events, cadence or output");
        $display("PASS fixed C4+G4 probe: events=%0d samples=%0d nonzero=%0d clips=%0d",
                 events, samples, nonzero, clips);
        $finish;
    end
    initial begin
        #150000000;
        $fatal(1, "fixed dyad probe timeout");
    end
endmodule

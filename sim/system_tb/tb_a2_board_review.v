`timescale 1ns/1ps
// Regression for the startup-volume clipping found in A's 359f090.
module tb_a2_board_review;
    reg clk = 0;
    always #40.6901 clk = ~clk;
    reg reset_button = 1;
    reg [15:0] pressed = 0;
    wire [3:0] rows;
    wire [3:0] cols = (rows[0] === 1'b0) ? ~pressed[3:0] :
                      (rows[1] === 1'b0) ? ~pressed[7:4] :
                      (rows[2] === 1'b0) ? ~pressed[11:8] :
                      (rows[3] === 1'b0) ? ~pressed[15:12] : 4'b1111;
    wire bck, ws, din, pa_en, led, locked;
    tri1 oled_scl, oled_sda;
    integer on_count = 0, off_count = 0, clips = 0, samples = 0;
    integer gap = 0, stage = 0, serial_ones = 0;
    reg prev_bck = 0;
    instrument_top dut (
        .i_clk_in(clk), .i_rst_n(reset_button), .col_in(cols), .row_out(rows),
        .enc_a(1'b1), .enc_b(1'b1), .enc_sw_n(1'b1),
        .oled_scl(oled_scl), .oled_sda(oled_sda),
        .o_hp_bck(bck), .o_hp_ws(ws), .o_hp_din(din),
        .o_pa_en(pa_en), .o_led(led), .o_locked(locked)
    );
    always @(posedge clk) begin
        if (dut.event_valid && dut.event_type == 1) on_count = on_count + 1;
        if (dut.event_valid && dut.event_type == 2) off_count = off_count + 1;
        if (!prev_bck && bck && din) serial_ones = serial_ones + 1;
        prev_bck = bck;
        if (stage != 0) begin
            gap = gap + 1;
            if (dut.audio_core_valid) begin
                if (samples != 0 && gap != 256) $fatal(1, "sample cadence gap");
                gap = 0;
                samples = samples + 1;
                if (dut.overload_flag) clips = clips + 1;
            end
            if (dut.event_overflow || dut.param_overflow || !locked)
                $fatal(1, "queue overflow or clock reset during held notes");
        end
    end
    task measure;
        input integer label_id;
        begin
            @(negedge clk);
            stage = label_id; clips = 0; samples = 0; gap = 0;
            repeat (6000) @(posedge dut.audio_core_valid);
            @(negedge clk);
            $display("BOARD REVIEW stage=%0d volume=%0d voices=%0d clips=%0d samples=%0d NOTE_ON=%0d NOTE_OFF=%0d",
                     stage, dut.u_audio_core.volume, dut.active_voice_count,
                     clips, samples, on_count, off_count);
            stage = 0;
        end
    endtask
    initial begin
        repeat (5) @(negedge clk);
        reset_button = 0;
        wait (dut.input_ready);
        if (dut.u_audio_core.volume != 33026) $fatal(1, "unexpected startup gain");
        @(negedge clk); pressed = 16'h0001;
        wait (dut.active_voice_count == 1);
        measure(1);
        if (on_count != 1 || off_count != 0 || clips != 0)
            $fatal(1, "held single-key events or output incorrect");
        @(negedge clk); pressed = 16'h0021;
        wait (dut.active_voice_count == 2);
        measure(2);
        if (on_count != 2 || off_count != 0) $fatal(1, "held dual-key events incorrect");
        @(negedge clk); pressed = 16'h8421;
        wait (dut.active_voice_count == 4);
        measure(4);
        if (on_count != 4 || off_count != 0) $fatal(1, "held chord events incorrect");
        if (clips != 0) $fatal(1, "startup-volume chord clipped");
        @(negedge clk); pressed = 0;
        // Allow release debounce before the configured ADSR tail.
        repeat (dut.u_audio_core.RELEASE_SAMPLES + 400) @(posedge dut.audio_core_valid);
        @(negedge clk);
        if (dut.active_voice_count != 0 || dut.audio_left != 0 || off_count != 4 || serial_ones == 0)
            $fatal(1, "release or I2S activity incorrect");
        $display("PASS board review: held single/dual/chord, zero clipping, ordered release");
        $finish;
    end
    initial begin
        #900000000;
        $fatal(1, "board review timeout");
    end
endmodule

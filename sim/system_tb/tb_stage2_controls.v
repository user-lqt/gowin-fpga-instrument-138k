`timescale 1ns/1ps
module tb_stage2_controls;
    reg clk = 0;
    always #40.6901 clk = ~clk;
    reg reset_button = 1;
    reg [15:0] pressed = 0;
    reg [1:0] enc_ab = 2'b11;
    wire [3:0] rows;
    wire [3:0] cols = (rows[0] === 1'b0) ? ~pressed[3:0] :
                      (rows[1] === 1'b0) ? ~pressed[7:4] :
                      (rows[2] === 1'b0) ? ~pressed[11:8] :
                      (rows[3] === 1'b0) ? ~pressed[15:12] : 4'b1111;
    wire bck, ws, din, pa_en, led, locked;
    tri1 oled_scl, oled_sda;
    integer on_count = 0, off_count = 0, clips = 0;
    integer i, before_on, before_off, peak64, peak65;
    reg [15:0] serial_shift = 0, dac_word = 0;
    reg previous_ws = 0;
    realtime pressed_at, latency_ms, max_latency_ms = 0;
    instrument_top dut (
        .i_clk_in(clk), .i_rst_n(reset_button), .col_in(cols), .row_out(rows),
        .enc_a(enc_ab[1]), .enc_b(enc_ab[0]), .enc_sw_n(1'b1),
        .oled_scl(oled_scl), .oled_sda(oled_sda),
        .o_hp_bck(bck), .o_hp_ws(ws), .o_hp_din(din),
        .o_pa_en(pa_en), .o_led(led), .o_locked(locked)
    );
    always @(posedge clk) begin
        if (dut.event_valid && dut.event_type == 1) on_count = on_count + 1;
        if (dut.event_valid && dut.event_type == 2) off_count = off_count + 1;
        if (dut.overload_flag) clips = clips + 1;
        if (dut.event_overflow || dut.param_overflow)
            $fatal(1, "two-dimension control overflowed a queue");
    end
    always @(posedge bck) begin
        if (!reset_button) begin
            if (ws != previous_ws) dac_word = serial_shift;
            serial_shift = {serial_shift[14:0], din};
            previous_ws = ws;
        end else begin
            dac_word = 0; serial_shift = 0; previous_ws = 0;
        end
    end
    task clockwise;
        begin
            @(negedge clk); enc_ab = 2'b10;
            repeat (1600) @(negedge clk); enc_ab = 2'b00;
            repeat (1600) @(negedge clk); enc_ab = 2'b01;
            repeat (1600) @(negedge clk); enc_ab = 2'b11;
            repeat (1600) @(negedge clk);
        end
    endtask
    task peak;
        output integer value;
        integer n, sample_value;
        begin
            value = 0;
            for (n = 0; n < 500; n = n + 1) begin
                @(posedge dut.audio_core_valid); @(negedge clk);
                sample_value = dut.audio_left;
                if (sample_value < 0) sample_value = -sample_value;
                if (sample_value > value) value = sample_value;
            end
        end
    endtask
    initial begin
        repeat (5) @(negedge clk); reset_button = 0;
        wait (dut.input_ready);
        // Different scan phases exercise the physical-key to decoded-word path.
        for (i = 0; i < 4; i = i + 1) begin
            #(i * 200000);
            @(negedge clk); pressed_at = $realtime; pressed = 1;
            wait (dac_word != 0);
            latency_ms = ($realtime - pressed_at) / 1000000.0;
            if (latency_ms > 10) $fatal(1, "key-to-DAC word exceeds 10 ms");
            if (latency_ms > max_latency_ms) max_latency_ms = latency_ms;
            $display("LATENCY phase=%0d key-to-decoded-DAC-word=%0.6f ms", i, latency_ms);
            @(negedge clk); pressed = 0;
            wait (dut.active_voice_count == 0);
            repeat (5) @(posedge dut.audio_core_valid);
            wait (dac_word == 0);
        end
        @(negedge clk); pressed = 1;
        wait (dut.active_voice_count == 1);
        repeat (3500) @(posedge dut.audio_core_valid);
        peak(peak64);
        before_on = on_count; before_off = off_count;
        clockwise();
        repeat (4) @(posedge dut.audio_core_valid);
        if (dut.u_input.volume_value != 65 || dut.u_audio_core.volume != 33542)
            $fatal(1, "encoder volume did not reach audio core");
        peak(peak65);
        if (peak65 <= peak64 || on_count != before_on || off_count != before_off)
            $fatal(1, "volume dimension altered notes or failed to change gain");
        for (i = 0; i < 62; i = i + 1) clockwise();
        repeat (4) @(posedge dut.audio_core_valid);
        if (dut.u_audio_core.volume != 65535) $fatal(1, "full volume not applied");
        @(negedge clk); pressed = 16'h8421;
        wait (dut.active_voice_count == 4);
        repeat (3500) @(posedge dut.audio_core_valid);
        before_on = on_count; before_off = off_count;
        // A brief contact dropout must not repeatedly release/retrigger voices.
        @(negedge clk); pressed = 0;
        #2000000;
        pressed = 16'h8421;
        repeat (5000) @(posedge dut.audio_core_valid);
        if (on_count != before_on || off_count != before_off ||
            dut.active_voice_count != 4 || clips != 0)
            $fatal(1, "held chord dropout caused retrigger or clipping");
        @(negedge clk); pressed = 0;
        wait (dut.active_voice_count == 0);
        repeat (5) @(posedge dut.audio_core_valid);
        if (dut.audio_left != 0) $fatal(1, "release failed to silence");
        @(negedge clk); reset_button = 1;
        repeat (5) @(negedge clk); reset_button = 0;
        wait (dut.input_ready);
        if (dut.u_audio_core.volume != 33026 || dut.active_voice_count != 0)
            $fatal(1, "reset failed to recover startup parameters");
        $display("PASS stage2 controls: peak64=%0d peak65=%0d maximum latency=%0.6f ms, four voices/full volume/no dropout retrigger/reset",
                 peak64, peak65, max_latency_ms);
        $finish;
    end
    initial begin
        #2200000000.0;
        $fatal(1, "stage2 controls timeout");
    end
endmodule

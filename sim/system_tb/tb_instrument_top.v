`timescale 1ns/1ps
module tb_instrument_top #(parameter OLED_PRESENT=0);
    reg clk = 0;
    always #40.6901 clk = ~clk;
    reg reset_button = 1;
    reg [15:0] pressed = 0;
    wire [3:0] rows;
    wire [3:0] cols = (rows[0] === 1'b0) ? ~pressed[3:0] :
                      (rows[1] === 1'b0) ? ~pressed[7:4] :
                      (rows[2] === 1'b0) ? ~pressed[11:8] :
                      (rows[3] === 1'b0) ? ~pressed[15:12] : 4'b1111;
    wire hp_bck, hp_ws, hp_din, pa_en, led, locked;
    tri1 oled_scl, oled_sda;
    reg oled_ack=0, oled_transaction=0;
    integer oled_bits=0, oled_bytes=0;
    reg [7:0] oled_shift=0;
    assign oled_sda=oled_ack ? 1'b0 : 1'bz;
    always @(negedge oled_sda) if (oled_scl===1'b1) begin
        oled_transaction=1; oled_bits=0; oled_bytes=0;
    end
    always @(posedge oled_sda) if (oled_scl===1'b1) oled_transaction=0;
    always @(posedge oled_scl) if (oled_transaction) begin
        if (oled_bits<8) begin oled_shift={oled_shift[6:0],oled_sda}; oled_bits=oled_bits+1; end
        else begin
            if (OLED_PRESENT && oled_bytes==0 && oled_shift!=8'h78)
                $fatal(1,"integrated OLED address incorrect");
            oled_bytes=oled_bytes+1; oled_bits=0;
        end
    end
    always @(negedge oled_scl)
        oled_ack=OLED_PRESENT && oled_transaction && oled_bits==8;
    integer note_on = 0, note_off = 0, nonzero = 0;
    integer serial_ones = 0, ws_changes = 0;
    reg prev_bck = 0, prev_ws = 0;
    instrument_top dut (
        .i_clk_in(clk), .i_rst_n(reset_button),
        .col_in(cols), .row_out(rows),
        .enc_a(1'b1), .enc_b(1'b1), .enc_sw_n(1'b1),
        .oled_scl(oled_scl), .oled_sda(oled_sda),
        .o_hp_bck(hp_bck), .o_hp_ws(hp_ws), .o_hp_din(hp_din),
        .o_pa_en(pa_en), .o_led(led), .o_locked(locked)
    );
    // Shorten only power settling in simulation; use the real bus divider.
    defparam dut.u_oled.POWERUP_CYCLES=12288;
    always @(posedge clk) begin
        if (dut.event_valid) begin
            if (dut.event_type == 2'd1) note_on = note_on + 1;
            if (dut.event_type == 2'd2) note_off = note_off + 1;
        end
        if (dut.audio_core_valid && dut.audio_left != 0) nonzero = nonzero + 1;
        if (!prev_bck && hp_bck && hp_din) serial_ones = serial_ones + 1;
        if (prev_ws != hp_ws) ws_changes = ws_changes + 1;
        prev_bck = hp_bck;
        prev_ws = hp_ws;
    end
    initial begin
        repeat (5) @(negedge clk);
        reset_button = 0;
        wait (dut.input_ready);
        if (dut.u_audio_core.volume != 16'd33026 || pa_en !== 1'b0)
            $fatal(1, "startup parameters or PA_EN incorrect");
        if (rows !== 4'bzzz0 && rows !== 4'bzz0z &&
            rows !== 4'bz0zz && rows !== 4'b0zzz)
            $fatal(1, "rows are not tri-stated");
        pressed = 1;
        wait (note_on == 1);
        repeat (100) @(posedge dut.sample_tick);
        if (nonzero < 50 || serial_ones < 20 || ws_changes < 10 ||
            dut.active_voice_count != 1 || !locked)
            $fatal(1, "note did not reach audio output");
        pressed = 0;
        wait (note_off == 1);
        repeat (dut.u_audio_core.RELEASE_SAMPLES + 5) @(posedge dut.sample_tick);
        if (dut.active_voice_count != 0 || dut.audio_left != 0)
            $fatal(1, "release did not silence audio");
        // One key per row and column avoids rectangles on a diode-less matrix.
        @(negedge clk); pressed=16'h8421;
        wait(dut.active_voice_count==4);
        repeat(1000) @(posedge dut.sample_tick);
        if(dut.event_overflow || dut.param_overflow)
            $fatal(1,"four-key chord caused overflow");
        @(negedge clk); pressed[0]=0;
        repeat(dut.u_audio_core.RELEASE_SAMPLES + 400) @(posedge dut.sample_tick);
        if(dut.active_voice_count!=3 || dut.audio_left==0)
            $fatal(1,"releasing one chord key disturbed the other voices");
        @(negedge clk); pressed=0;
        repeat(dut.u_audio_core.RELEASE_SAMPLES + 400) @(posedge dut.sample_tick);
        if(dut.active_voice_count!=0 || dut.audio_left!=0)
            $fatal(1,"chord release left stuck notes");
        if (OLED_PRESENT && (!dut.oled_initialized || dut.oled_fault))
            $fatal(1,"OLED did not render while instrument played");
        if (!OLED_PRESENT && (!dut.oled_fault || dut.oled_initialized))
            $fatal(1,"missing OLED was not isolated from audio");
        $display("PASS instrument_top note on/off and four-key ADSR chord through real B and A, nonzero=%0d", nonzero);
        $finish;
    end
    initial begin
        #1100000000;
        $fatal(1, "instrument top timeout");
    end
endmodule

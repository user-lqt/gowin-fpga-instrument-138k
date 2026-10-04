`timescale 1ns/1ps
module tb_instrument_24_rgb;
    reg reference=0, reset_button=1;
    always #10 reference=~reference;
    reg [47:0] contacts=0;
    reg enc_a=1, enc_b=1, enc_sw_n=1;
    wire [7:0] rows;
    reg [5:0] cols;
    integer r;
    always @* begin
        cols=6'h3f;
        for(r=0;r<8;r=r+1)
            if(rows[r]===1'b0) cols=cols & ~contacts[r*6+:6];
    end
    wire lcd_clk, lcd_hs, lcd_vs, lcd_de;
    wire [5:0] red, green, blue;
    wire bck, ws, din;
    instrument_24_rgb_top dut (
        .i_clk_in(reference), .i_rst_n(reset_button), .col_in(cols),
        .enc_a(enc_a), .enc_b(enc_b), .enc_sw_n(enc_sw_n), .row_out(rows),
        .o_hp_bck(bck), .o_hp_ws(ws), .o_hp_din(din), .o_pa_en(), .o_led(), .o_locked(),
        .lcd_sc_clk(lcd_clk), .lcd_sc_hs(lcd_hs), .lcd_sc_vs(lcd_vs), .lcd_sc_de(lcd_de),
        .lcd_r_out(red), .lcd_g_out(green), .lcd_b_out(blue)
    );
    // Preserve the real scan and event pacing; shorten only release for runtime.
    defparam dut.u_audio_core.RELEASE_SAMPLES=48;
    integer ons=0, offs=0, nonzero=0, serial_ones=0;
    always @(posedge dut.clk_audio) begin
        if(dut.event_valid && dut.event_type==1) ons=ons+1;
        if(dut.event_valid && dut.event_type==2) offs=offs+1;
        if(dut.audio_core_valid && dut.audio_left!=0) nonzero=nonzero+1;
        if(dut.event_overflow || dut.param_overflow) $fatal(1,"integrated input queue overflow");
    end
    always @(posedge bck) if(din) serial_ones=serial_ones+1;
    task samples;
        input integer n;
        repeat(n) @(posedge dut.sample_tick);
    endtask
    initial begin
        repeat(5) @(negedge reference); reset_button=0;
        wait(dut.keyboard_ready); samples(5);
        if(dut.u_audio_core.volume!=33026) $fatal(1,"startup volume failed");
        contacts=48'h41;
        wait(ons==1); samples(600);
        if(dut.active_voice_count!=1 || nonzero<100 || serial_ones<100)
            $fatal(1,"key did not reach DAC");
        // Both contacts of every key close: 24 events, four accepted voices.
        contacts=48'hffffffffffff;
        wait(ons==24); samples(600);
        if(dut.active_voice_count!=4) $fatal(1,"four-voice integration failed");
        // Across two different clock domains, the whole mask must arrive.
        wait(dut.u_lcd.frame_keys==24'hffffff);
        contacts=0; wait(offs==24); samples(100);
        if(dut.active_voice_count!=0 || dut.audio_left!=0) $fatal(1,"release stuck audio");
        wait(dut.u_lcd.frame_keys==0);
        reset_button=1;
        repeat(10) @(negedge reference);
        if(rows!==8'hzz || dut.active_voice_count!=0 || lcd_de!==0)
            $fatal(1,"reset did not clear keyboard/audio/display");
        $display("PASS instrument24 scan-to-DAC, 24-key burst, four voices, atomic display update and reset");
        $finish;
    end
    initial begin #200000000; $fatal(1,"instrument24 timeout"); end
endmodule

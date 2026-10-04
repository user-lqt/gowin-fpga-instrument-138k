`timescale 1ns/1ps
module tb_ec11_formal;
    reg reference=0, reset_button=1;
    always #10 reference=~reference;
    reg a=1,b=1,sw=1;
    integer i;
    instrument_24_rgb_top dut (
        .i_clk_in(reference), .i_rst_n(reset_button), .col_in(6'h3f),
        .enc_a(a), .enc_b(b), .enc_sw_n(sw), .row_out(),
        .enc2_a(1'b1),.enc2_b(1'b1),.enc2_sw_n(1'b1),
        .o_hp_bck(), .o_hp_ws(), .o_hp_din(), .o_pa_en(), .o_led(), .o_locked(),
        .lcd_sc_clk(), .lcd_sc_hs(), .lcd_sc_vs(), .lcd_sc_de(),
        .lcd_r_out(), .lcd_g_out(), .lcd_b_out()
    );
    defparam dut.u_encoder_control.BUTTON_CYCLES=100;
    task settle;
        repeat(600) @(negedge dut.clk_audio);
    endtask
    task phase;
        input [1:0] ab;
        begin {a,b}=ab; repeat(2700) @(negedge dut.clk_audio); end
    endtask
    task clockwise;
        begin phase(2'b10); phase(2'b00); phase(2'b01); phase(2'b11); settle; end
    endtask
    task counterclockwise;
        begin phase(2'b01); phase(2'b00); phase(2'b10); phase(2'b11); settle; end
    endtask
    task press;
        input [1:0] expected;
        begin
            // Bounce before valid closure must not select a timbre.
            sw=0; repeat(10) @(negedge dut.clk_audio);
            sw=1; repeat(10) @(negedge dut.clk_audio);
            sw=0; settle;
            if(dut.instrument_value!=expected || dut.u_audio_core.instrument!=expected || dut.ui_page!=0)
                $fatal(1,"timbre press failed");
            settle;
            if(dut.instrument_value!=expected) $fatal(1,"held button repeated");
            sw=1; settle;
        end
    endtask
    initial begin
        repeat(5) @(negedge reference); reset_button=0;
        wait(dut.encoder_ready); settle;
        if(dut.volume_value!=64 || dut.instrument_value!=0 || dut.u_audio_core.volume!=33026)
            $fatal(1,"startup defaults failed");
        clockwise;
        if(dut.volume_value!=68 || dut.u_audio_core.volume!=35090) $fatal(1,"volume step failed");
        press(1); clockwise;
        if(dut.volume_value!=72 || dut.instrument_value!=1) $fatal(1,"rotation changed timbre");
        press(2); press(0);
        for(i=0;i<20;i=i+1) clockwise;
        if(dut.volume_value!=127 || dut.u_audio_core.volume!=65535) $fatal(1,"maximum clamp failed");
        for(i=0;i<34;i=i+1) counterclockwise;
        if(dut.volume_value!=0 || dut.u_audio_core.volume!=0) $fatal(1,"minimum clamp failed");
        // Coincident events must both be emitted through the single parameter port.
        @(negedge dut.clk_audio);
        force dut.u_encoder_control.parameters.step_up=1;
        force dut.u_encoder_control.parameters.select_press=1;
        @(negedge dut.clk_audio);
        release dut.u_encoder_control.parameters.step_up;
        release dut.u_encoder_control.parameters.select_press;
        settle;
        if(dut.volume_value!=4 || dut.instrument_value!=1 || dut.u_audio_core.instrument!=1 || dut.u_audio_core.volume!=2064)
            $fatal(1,"coincident volume/timbre update lost");
        wait(dut.u_lcd.frame_volume==4 && dut.u_lcd.frame_instrument==1);
        wait(dut.u_lcd.h_count==570 && dut.u_lcd.v_count==30);
        @(negedge dut.pixel_clk); #1;
        if(dut.u_lcd.r_out!=5 || dut.u_lcd.g_out!=9 || dut.u_lcd.b_out!=13)
            $fatal(1,"diagnostic overlay still visible");
        reset_button=1; repeat(10) @(negedge reference); reset_button=0;
        wait(dut.encoder_ready); settle;
        if(dut.volume_value!=64 || dut.instrument_value!=0) $fatal(1,"reset defaults failed");
        $display("PASS formal EC11 step4, clamps, 3 timbres/wrap, bounce/hold, concurrent events, audio and clean display/reset");
        $finish;
    end
    initial begin #200000000; $fatal(1,"formal EC11 timeout"); end
endmodule

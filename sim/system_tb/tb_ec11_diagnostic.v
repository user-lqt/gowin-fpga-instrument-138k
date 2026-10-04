`timescale 1ns/1ps
module tb_ec11_diagnostic;
    reg reference=0, reset_button=1;
    always #10 reference=~reference;
    reg a=1, b=1, sw=1;
    instrument_24_rgb_top dut (
        .i_clk_in(reference), .i_rst_n(reset_button), .col_in(6'h3f),
        .enc_a(a), .enc_b(b), .enc_sw_n(sw), .row_out(),
        .o_hp_bck(), .o_hp_ws(), .o_hp_din(), .o_pa_en(), .o_led(), .o_locked(),
        .lcd_sc_clk(), .lcd_sc_hs(), .lcd_sc_vs(), .lcd_sc_de(),
        .lcd_r_out(), .lcd_g_out(), .lcd_b_out()
    );
    // Keep the real 2500-clock rotation filter; accelerate only button debounce.
    defparam dut.u_encoder_control.BUTTON_CYCLES=100;
    task phase;
        input [1:0] ab;
        begin {a,b}=ab; repeat(2700) @(negedge dut.clk_audio); end
    endtask
    task check_pixel;
        input integer x,y;
        input [5:0] r,g,b_color;
        begin
            wait(dut.u_lcd.h_count==x && dut.u_lcd.v_count==y);
            @(negedge dut.pixel_clk); #1;
            if(dut.u_lcd.r_out!==r || dut.u_lcd.g_out!==g || dut.u_lcd.b_out!==b_color)
                $fatal(1,"diagnostic pixel failed at %0d,%0d",x,y);
        end
    endtask
    initial begin
        repeat(5) @(negedge reference); reset_button=0;
        wait(dut.encoder_ready); phase(2'b11);
        phase(2'b10); phase(2'b00); phase(2'b01); phase(2'b11);
        repeat(600) @(negedge dut.clk_audio);
        if(dut.diagnostic_up!=1 || dut.diagnostic_down!=0 || dut.diagnostic_edges!=4 ||
           dut.volume_value!=65 || dut.u_audio_core.volume!=33542)
            $fatal(1,"CW event/volume/audio chain failed");
        phase(2'b01); phase(2'b00); phase(2'b10); phase(2'b11);
        repeat(600) @(negedge dut.clk_audio);
        if(dut.diagnostic_up!=1 || dut.diagnostic_down!=1 || dut.diagnostic_edges!=8 || dut.volume_value!=64)
            $fatal(1,"CCW chain failed");
        sw=0; repeat(120) @(negedge dut.clk_audio);
        if(dut.ui_page!=1) $fatal(1,"button/page failed");
        wait(dut.u_lcd.frame_diagnostic==dut.diagnostic_status);
        if(dut.u_lcd.frame_diagnostic[3:0]!=4'b1011) $fatal(1,"pad snapshot failed");
        check_pixel(570,30,10,58,10);
        check_pixel(665,30,58,10,10);
        check_pixel(710,30,10,58,10);
        check_pixel(49,104,58,39,10);
        check_pixel(49,118,10,54,54);
        check_pixel(49,132,56,12,42);
        $display("PASS EC11 pads, CW/CCW counters, audio volume, button, CDC and diagnostic pixels");
        $finish;
    end
    initial begin #200000000; $fatal(1,"EC11 diagnostic timeout"); end
endmodule

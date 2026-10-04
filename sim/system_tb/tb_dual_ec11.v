`timescale 1ns/1ps
module tb_dual_ec11;
    reg reference=0,reset_button=1;
    always #10 reference=~reference;
    reg a=1,b=1,sw=1,a2=1,b2=1,sw2=1;
    integer glide_events=0,effect_events=0,i;
    reg [15:0] last_glide=0,last_effect=0;
    instrument_24_rgb_top dut(
        .i_clk_in(reference),.i_rst_n(reset_button),.col_in(6'h3f),
        .enc_a(a),.enc_b(b),.enc_sw_n(sw),.enc2_a(a2),.enc2_b(b2),.enc2_sw_n(sw2),
        .row_out(),.o_hp_bck(),.o_hp_ws(),.o_hp_din(),.o_pa_en(),.o_led(),.o_locked(),
        .lcd_sc_clk(),.lcd_sc_hs(),.lcd_sc_vs(),.lcd_sc_de(),.lcd_r_out(),.lcd_g_out(),.lcd_b_out());
    defparam dut.u_encoder_b.BUTTON_CYCLES=100;
    task settle;repeat(900) @(negedge dut.clk_audio);endtask
    task phase;
        input [1:0] ab;
        begin {a2,b2}=ab;repeat(2700) @(negedge dut.clk_audio);end
    endtask
    task cw;begin phase(2'b10);phase(2'b00);phase(2'b01);phase(2'b11);settle;end endtask
    task ccw;begin phase(2'b01);phase(2'b00);phase(2'b10);phase(2'b11);settle;end endtask
    task press;
        begin sw2=0;repeat(10) @(negedge dut.clk_audio);sw2=1;repeat(10) @(negedge dut.clk_audio);
            sw2=0;settle;sw2=1;settle;end
    endtask
    always @(posedge dut.clk_audio) begin
        if(dut.param_valid && dut.param_id==6) begin glide_events=glide_events+1;last_glide=dut.param_value;end
        if(dut.param_valid && dut.param_id==5) begin effect_events=effect_events+1;last_effect=dut.param_value;end
        if(dut.control_overflow || dut.param_overflow) $fatal(1,"dual encoder queue overflow");
    end
    initial begin
        repeat(5) @(negedge reference);reset_button=0;
        wait(dut.encoder_b_ready);settle;
        if(glide_events!=1 || effect_events!=1 || dut.volume_value!=64 || dut.u_audio_core.volume!=33026)
            $fatal(1,"dual startup failed");
        cw;
        if(dut.glide_value!=4 || last_glide!=2064 || dut.effect_value!=0) $fatal(1,"glide update failed");
        press;
        if(!dut.encoder_b_menu || dut.glide_value!=4) $fatal(1,"menu switch failed");
        cw;
        if(dut.effect_value!=4 || last_effect!=2064 || dut.glide_value!=4) $fatal(1,"effect update failed");
        for(i=0;i<32;i=i+1) cw;
        if(dut.effect_value!=127 || last_effect!=65535) $fatal(1,"effect maximum failed");
        for(i=0;i<33;i=i+1) ccw;
        if(dut.effect_value!=0 || last_effect!=0) $fatal(1,"effect minimum failed");
        press;
        if(dut.encoder_b_menu || dut.glide_value!=4) $fatal(1,"menu value not retained");
        // Both controls emit a change on exactly the same clock.
        @(negedge dut.clk_audio);
        force dut.u_encoder_control.parameters.step_up=1;
        force dut.u_encoder_b.up=1;
        @(negedge dut.clk_audio);
        release dut.u_encoder_control.parameters.step_up;release dut.u_encoder_b.up;
        settle;
        if(dut.volume_value!=68 || dut.u_audio_core.volume!=35090 || dut.glide_value!=8 || last_glide!=4128)
            $fatal(1,"concurrent A/B update failed");
        wait(dut.u_lcd.frame_glide==8 && dut.u_lcd.frame_effect==0);
        wait(dut.u_lcd.h_count==49 && dut.u_lcd.v_count==470);
        @(negedge dut.pixel_clk);#1;
        if(dut.u_lcd.g_out!=54) $fatal(1,"B display bar failed");
        // The current A core has no glide/effect processing; it must retain
        // the existing volume/timbre behavior when those IDs are received.
        if(dut.u_audio_core.instrument!=0) $fatal(1,"B changed A timbre");
        $display("PASS dual EC11 menus, clamps, retained values, protocol, concurrent queue and LCD; audio effects remain pending");$finish;
    end
    initial begin #200000000;$fatal(1,"dual EC11 timeout");end
endmodule

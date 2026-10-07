`timescale 1ns/1ps
module tb_instrument_fsr_vibrato #(parameter integer ENABLE_JOYSTICK=1);
    reg reference=0, reset_button=1;
    always #10 reference=~reference;
    reg [47:0] contacts=0;
    wire [7:0] rows;
    reg [5:0] cols;
    integer row;
    always @* begin
        cols=6'h3f;
        for(row=0;row<8;row=row+1)
            if(rows[row]===1'b0) cols=cols & ~contacts[row*6+:6];
    end
    reg [9:0] pressure=1, x=512, y=1023;
    reg encoder_button=1;
    reg adc_disconnected=0;
    wire cs_n,sclk,mosi,miso,model_miso,bck,ws,din;
    assign miso=adc_disconnected ? 1'b1 : model_miso;
    mcp3008_model adc(.cs_n(cs_n),.sclk(sclk),.mosi(mosi),
        .ch0(pressure),.ch1(x),.ch2(y),.miso(model_miso));
    instrument_24_rgb_top #(.ROW_CYCLES(4),.DEBOUNCE_FRAMES(2),
        .ADC_SAMPLE_DIV(512),.ENABLE_JOYSTICK(ENABLE_JOYSTICK)) dut (
        .i_clk_in(reference),.i_rst_n(reset_button),.col_in(cols),.row_out(rows),
        .enc_a(1'b1),.enc_b(1'b1),.enc_sw_n(encoder_button),
        .enc2_a(1'b1),.enc2_b(1'b1),.enc2_sw_n(1'b1),
        .adc_miso(miso),.adc_cs_n(cs_n),.adc_sclk(sclk),.adc_mosi(mosi),
        .o_hp_bck(bck),.o_hp_ws(ws),.o_hp_din(din),.o_pa_en(),.o_led(),.o_locked(),
        .lcd_sc_clk(),.lcd_sc_hs(),.lcd_sc_vs(),.lcd_sc_de(),
        .lcd_r_out(),.lcd_g_out(),.lcd_b_out()
    );
    defparam dut.u_audio_core.ATTACK_SAMPLES=8;
    defparam dut.u_audio_core.DECAY_SAMPLES=16;
    defparam dut.u_audio_core.RELEASE_SAMPLES=32;
    defparam dut.u_encoder_control.BUTTON_CYCLES=4;
    integer ons=0,offs=0,pcm_nonzero=0,stereo_pairs=0,bell_modulated=0;
    integer last_adc_start=-1,cycles=0;
    reg [15:0] left_slot;
    reg have_left=0;
    reg [31:0] first_fc,last_fc;
    reg check_neutral_pitch=0;
    always @(posedge dut.clk_audio) begin
        cycles=cycles+1;
        if(dut.event_valid && dut.event_type==1) ons=ons+1;
        if(dut.event_valid && dut.event_type==2) offs=offs+1;
        if(dut.audio_core_valid) begin
            if((^dut.audio_left)===1'bx) $fatal(1,"unknown integrated PCM");
            if(dut.audio_left!=0) pcm_nonzero=pcm_nonzero+1;
            if(check_neutral_pitch && dut.active_voice_count==1 &&
               dut.u_audio_core.a2.rendered_fc[31:0]!==dut.u_audio_core.a2.voice_fc[31:0])
                $fatal(1,"neutral FSR left continuous pitch modulation");
        end
        if(dut.event_overflow || dut.param_overflow || dut.control_overflow)
            $fatal(1,"integrated queue overflow");
        if(dut.overload_flag) $fatal(1,"integrated PCM clipped");
        if(dut.rst_n && dut.sample_tick && dut.u_audio_core.a2.expression.u_pitch.busy)
            $fatal(1,"integrated expression missed sample deadline");
        if(dut.u_mcp3008_sampler.start) begin
            if(last_adc_start>=0 && cycles-last_adc_start!=512)
                $fatal(1,"shared ADC sampling cadence");
            last_adc_start=cycles;
        end
        // Check what the real serial transmitter loads for both DAC slots.
        if(dut.u_i2s_tx.bck_fall_event && dut.u_i2s_tx.req_r1) begin
            if(dut.u_i2s_tx.b_cnt<16) begin
                left_slot=dut.u_i2s_tx.selected_data;have_left=1;
            end else if(have_left) begin
                if(dut.u_i2s_tx.selected_data!==left_slot)
                    $fatal(1,"DAC loaded different mono frames into L/R");
                stereo_pairs=stereo_pairs+1;
            end
        end
    end
    task samples;
        input integer count;
        begin repeat(count) begin @(posedge dut.sample_tick);@(negedge dut.clk_audio);end end
    endtask
    task next_timbre;
        begin
            encoder_button=0;samples(2);
            encoder_button=1;samples(2);
        end
    endtask
    initial begin
        repeat(5) @(negedge reference);reset_button=0;
        wait(dut.keyboard_ready && dut.fsr_sensor_ready);samples(530);
        if(dut.u_audio_core.a2.expression.u_pitch.u_vibrato.depth_target!=0)
            $fatal(1,"joystick Y overwrote neutral FSR");
        if(dut.adc_ch0!=1 || dut.adc_digits!==16'h0001 || dut.fsr_digits!==16'h0000)
            $fatal(1,"measured neutral ADC/decimal readout mismatch");
        wait(dut.u_lcd.frame_sensor_ready);
        if(dut.u_lcd.frame_adc_digits!==16'h0001 || dut.u_lcd.frame_vibrato_digits!==12'h000)
            $fatal(1,"neutral telemetry did not cross to display atomically");
        contacts=48'h41;wait(ons==1);samples(50);
        if(dut.active_voice_count!=1 || pcm_nonzero<10)
            $fatal(1,"held key not sounding before pressure");
        check_neutral_pitch=1;samples(300);check_neutral_pitch=0;
        pressure=899;
        wait(dut.fsr_modulation==65535);samples(280);
        if(dut.u_audio_core.a2.expression.u_pitch.u_vibrato.depth!=65535)
            $fatal(1,"FSR depth did not reach audio LFO");
        if(dut.adc_digits!==16'h0899 || dut.fsr_digits!==16'h0100)
            $fatal(1,"measured heavy-pressure decimal readout mismatch");
        first_fc=dut.u_audio_core.a2.rendered_fc[31:0];samples(100);
        last_fc=dut.u_audio_core.a2.rendered_fc[31:0];
        if(first_fc==last_fc || ons!=1 || offs!=0 || dut.active_voice_count!=1)
            $fatal(1,"vibrato did not move held pitch continuously");
        y=0;samples(100);
        if(dut.u_audio_core.a2.expression.u_pitch.u_vibrato.depth_target!=65535)
            $fatal(1,"joystick Y overwrote held FSR depth");
        x=1023;
        // The signed Q12 interface has an asymmetric +8191/-8192 limit.
        if(ENABLE_JOYSTICK != 0)
            wait(dut.u_audio_core.a2.expression.u_pitch.bend==8191);
        else begin
            samples(100);
            if(dut.adc_sample_channel!=0 ||
               dut.u_audio_core.a2.expression.u_pitch.bend!=0)
                $fatal(1,"unconnected joystick changed pitch or was sampled");
        end
        if(dut.u_audio_core.a2.expression.u_pitch.u_vibrato.depth!=65535)
            $fatal(1,"bend and vibrato did not coexist");
        pressure=1;x=512;
        wait(dut.fsr_modulation==0);samples(280);
        if(dut.u_audio_core.a2.expression.u_pitch.u_vibrato.pitch_offset!=0 ||
           dut.u_audio_core.a2.expression.u_pitch.bend!=0)
            $fatal(1,"release pressure/center joystick did not restore pitch");
        samples(2);
        if(dut.u_audio_core.a2.rendered_fc[31:0]!==dut.u_audio_core.a2.voice_fc[31:0] ||
           dut.active_voice_count!=1 || ons!=1 || offs!=0)
            $fatal(1,"pressure release changed note or left detuning");
        check_neutral_pitch=1;samples(300);check_neutral_pitch=0;
        pressure=899;
        wait(dut.fsr_modulation==65535);samples(280);
        @(negedge cs_n);adc_disconnected=1;
        wait(!dut.fsr_sensor_ready);samples(280);
        if(dut.u_audio_core.a2.expression.u_pitch.u_vibrato.depth_target!=0 ||
           dut.u_audio_core.a2.expression.u_pitch.u_vibrato.pitch_offset!=0)
            $fatal(1,"pulled-high ADC left maximum vibrato enabled");
        if(dut.fsr_display_ready || dut.adc_digits!=0 || dut.fsr_digits!=0)
            $fatal(1,"failed ADC displayed a valid full-scale pressure");
        @(posedge cs_n);adc_disconnected=0;pressure=1;
        wait(dut.fsr_sensor_ready);samples(300);
        if(dut.adc_digits!==16'h0001 || dut.fsr_digits!==16'h0000)
            $fatal(1,"valid ADC did not recover after disconnected DOUT");
        contacts=0;wait(offs==1);samples(45);
        if(dut.active_voice_count!=0 || dut.audio_left!=0 || dut.dac_frame_left!=0 || stereo_pairs<100)
            $fatal(1,"note release/DAC frame buffer");
        next_timbre;
        if(dut.instrument_value!=1 || dut.u_audio_core.instrument!=2)
            $fatal(1,"encoder bell slot did not map to audio ID 2");
        pressure=899;
        wait(dut.fsr_modulation==65535);samples(280);
        contacts=48'h41;wait(ons==2);samples(80);
        if(dut.active_voice_count!=1 || dut.u_audio_core.a2.voice_instrument[1:0]!=2)
            $fatal(1,"bell key did not sound with vibrato");
        // The LFO crosses zero twice per period; one snapshot can be neutral.
        repeat(64) begin
            samples(1);
            if(dut.u_audio_core.a2.rendered_fc[31:0]!==dut.u_audio_core.a2.voice_fc[31:0])
                bell_modulated=bell_modulated+1;
        end
        if(bell_modulated==0) $fatal(1,"bell pitch not modulated");
        contacts=0;wait(offs==2);samples(45);
        if(dut.active_voice_count!=0 || dut.audio_left!=0) $fatal(1,"bell release stuck");
        next_timbre;
        if(dut.instrument_value!=0 || dut.u_audio_core.instrument!=0)
            $fatal(1,"two-timbre encoder cycle did not wrap to piano");
        reset_button=1;repeat(10) @(negedge reference);
        if(dut.fsr_sensor_ready || dut.fsr_display_ready || dut.adc_digits!=0 ||
           dut.fsr_digits!=0 || dut.dac_frame_left!=0 || rows!==8'hzz)
            $fatal(1,"integrated reset did not clear pressure/audio/keyboard");
        $display("PASS datasheet SPI ADC 1/899 -> FSR -> vibrato -> DAC; disconnected DOUT disables depth; joystick enable=%0d; piano/bell, telemetry and reset",ENABLE_JOYSTICK);
        $finish;
    end
    initial begin #150000000;$fatal(1,"integrated FSR timeout");end
endmodule

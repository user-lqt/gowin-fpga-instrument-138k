`timescale 1ns/1ps
module tb_strike_expression;
    reg clk=0, rst_n=0, on=0;
    always #5 clk=~clk;
    wire signed [23:0] soft_audio, hard_audio;
    voice #(.ATTACK_SAMPLES(1),.DECAY_SAMPLES(1),.SUSTAIN_LEVEL(65535)) soft_voice
      (.clk(clk),.rst_n(rst_n),.sample_tick(1'b1),.note_on(on),.note_off(1'b0),
       .note_id(7'd69),.velocity(8'd24),.instrument(2'd0),.audio(soft_audio),
       .active(),.envelope_level(),.envelope_stage());
    voice #(.ATTACK_SAMPLES(1),.DECAY_SAMPLES(1),.SUSTAIN_LEVEL(65535)) hard_voice
      (.clk(clk),.rst_n(rst_n),.sample_tick(1'b1),.note_on(on),.note_off(1'b0),
       .note_id(7'd69),.velocity(8'd127),.instrument(2'd0),.audio(hard_audio),
       .active(),.envelope_level(),.envelope_stage());
    real soft_energy=0, hard_energy=0;
    integer i, soft_crossings=0, hard_crossings=0;
    reg signed [23:0] prev_soft=0, prev_hard=0;
    keyboard_24_dual #(.AB_MAX_FRAMES(5004)) curve_check
      (.clk(clk),.rst_n(rst_n),.scan_valid(1'b0),.contact_raw(48'd0),
       .event_valid(),.event_type(),.key_id(),.velocity(),.key_state());
    initial begin
        if(curve_check.travel_velocity(1)!=127 || curve_check.travel_velocity(5002)!=127 ||
           curve_check.travel_velocity(5003)!=127 || curve_check.travel_velocity(5004)!=16)
            $fatal(1,"1 second strike boundary failed");
        repeat(4) @(negedge clk); rst_n=1;
        @(negedge clk); on=1;
        @(negedge clk); on=0;
        repeat(20) @(negedge clk);
        if(soft_voice.sounding_note != 57 || hard_voice.sounding_note != 69)
            $fatal(1,"slow/fast pitch mapping failed");
        for(i=0;i<4800;i=i+1) begin
            @(negedge clk);
            soft_energy=soft_energy+$itor(soft_audio)*$itor(soft_audio);
            hard_energy=hard_energy+$itor(hard_audio)*$itor(hard_audio);
            if(prev_soft <= 0 && soft_audio > 0) soft_crossings=soft_crossings+1;
            if(prev_hard <= 0 && hard_audio > 0) hard_crossings=hard_crossings+1;
            prev_soft=soft_audio; prev_hard=hard_audio;
        end
        if(hard_energy/soft_energy < 5.0 || hard_energy/soft_energy > 7.5)
            $fatal(1,"slow strike is not near 40 percent gain");
        if(hard_crossings < 2*soft_crossings-2 || hard_crossings > 2*soft_crossings+2)
            $fatal(1,"slow strike frequency is not one octave lower");
        $display("PASS strike expression: energy ratio=%f, slow/fast cycles=%0d/%0d",hard_energy/soft_energy,soft_crossings,hard_crossings);
        $finish;
    end
endmodule

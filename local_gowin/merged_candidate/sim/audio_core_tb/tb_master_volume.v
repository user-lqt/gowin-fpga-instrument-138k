`timescale 1ns/1ps
`include "event_defs.vh"
module tb_master_volume;
 reg clk=0,rst_n=0,ev=0,pv=0;
 reg [7:0] divider=0;
 reg [3:0] pid=0;
 reg [15:0] value=0;
 wire valid,ready,overload,eo,po;
 wire signed [23:0] left,right;
 always #5 clk=~clk;
 always @(posedge clk) if(!rst_n) divider<=0;else divider<=divider+1'b1;
 // Four allocated slots exercise the same gain/mixer path; one note is active.
 // The production top remains 32 slots and is checked separately.
 audio_core #(.VOICE_COUNT(4),.ENABLE_EXPRESSION(1),.ENABLE_GUITAR(1),
  .RAM_BODY(1),.SHARE_VOICE_ARITHMETIC(1),.ATTACK_SAMPLES(8),.DECAY_SAMPLES(32)) dut(
  .clk(clk),.rst_n(rst_n),.sample_tick(divider==255),
  .event_valid(ev),.event_type(`EVENT_NOTE_ON),.note_id(7'd60),.velocity(8'd127),
  .param_valid(pv),.param_id(pid),.param_value(value),
  .audio_core_valid(valid),.audio_left(left),.audio_right(right),
  .engine_ready(ready),.overload_flag(overload),.event_overflow(eo),.param_overflow(po));
 task parameter_event;input [3:0] id;input [15:0] v;begin
  @(negedge clk);pv=1;pid=id;value=v;@(negedge clk);pv=0;
  repeat(512) @(negedge clk);
 end endtask
 integer timbre,level,samples,pcm_magnitude;
 reg [63:0] energy,previous_energy;
 initial begin
  for(timbre=0;timbre<3;timbre=timbre+1) begin
   for(level=0;level<3;level=level+1) begin
    rst_n=0;ev=0;pv=0;repeat(5) @(negedge clk);rst_n=1;wait(ready);
    parameter_event(`PARAM_VOLUME,level==0 ? 0 : level==1 ? 8191 : 12286);
    // Production audio ramps the master gain by 64 per sample to avoid clicks.
    // Measure only after that ramp, not while the reset default is fading.
    wait(dut.volume==dut.volume_target);
    repeat(512) @(negedge clk);
    parameter_event(`PARAM_INSTRUMENT,timbre);
    @(negedge clk);ev=1;@(negedge clk);ev=0;
    energy=0;samples=0;
    while(samples<256) begin
     @(negedge clk);
     if(eo || po || overload) $fatal(1,"single-note gain overflow");
     if(valid) begin
      if((^left)===1'bx || left!==right) $fatal(1,"invalid PCM");
      pcm_magnitude=$signed(left);
      if(pcm_magnitude<0) pcm_magnitude=-pcm_magnitude;
      energy=energy+pcm_magnitude;samples=samples+1;
     end
    end
    if(level==0 && energy!=0) $fatal(1,"zero gain audible");
    if(level==1) begin
     if(energy==0) $fatal(1,"silent reference");previous_energy=energy;
    end
    if(level==2 && (energy*100<previous_energy*145 || energy*100>previous_energy*155))
     $fatal(1,"gain ratio timbre=%0d old=%0d new=%0d",timbre,previous_energy,energy);
    $display("volume measurement timbre=%0d level=%0d energy=%0d",timbre,level,energy);
   end
  end
  $display("PASS: all three timbres, zero volume silence, new maximum PCM amplitude 1.5x previous maximum, single-note no clipping");$finish;
 end
 initial begin #20000000;$fatal(1,"timeout");end
endmodule

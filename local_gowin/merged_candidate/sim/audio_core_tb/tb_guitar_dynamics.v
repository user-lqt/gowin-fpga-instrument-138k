`timescale 1ns/1ps
`include "event_defs.vh"
module tb_guitar_dynamics;
 reg clk=0,rst_n=0,ev=0,pv=0;
 always #5 clk=~clk;
 reg [7:0] divider=0,velocity=0;
 reg [6:0] note=48;
 reg [3:0] pid=0;
 reg [15:0] value=0;
 wire valid,ready,overload,eo,po;
 wire signed [23:0] left,right;
 wire [7:0] gain;
 strike_profile profile(.velocity(velocity),.instrument(2'd1),.gain(gain));
 always @(posedge clk)
  if(!rst_n) divider<=0; else divider<=divider+1'b1;
 audio_core #(.VOICE_COUNT(4),.ENABLE_EXPRESSION(1),.ENABLE_GUITAR(1),
  .RAM_BODY(1),.SHARE_VOICE_ARITHMETIC(1),
  .ATTACK_SAMPLES(8),.DECAY_SAMPLES(32)) dut(
  .clk(clk),.rst_n(rst_n),.sample_tick(divider==255),
  .event_valid(ev),.event_type(`EVENT_NOTE_ON),.note_id(note),.velocity(velocity),
  .param_valid(pv),.param_id(pid),.param_value(value),
  .audio_core_valid(valid),.audio_left(left),.audio_right(right),
  .engine_ready(ready),.overload_flag(overload),.event_overflow(eo),.param_overflow(po));
 task parameter_event;input [3:0] id;input [15:0] v;begin
  @(negedge clk);pv=1;pid=id;value=v;@(negedge clk);pv=0;
  repeat(512) @(negedge clk);
 end endtask
 integer n,level,samples,magnitude,v,previous_gain;
 reg [63:0] energy,previous_energy;
 initial begin
  previous_gain=0;
  for(v=0;v<256;v=v+1) begin
   velocity=v;#1;
   if(gain<previous_gain || gain>206) $fatal(1,"guitar gain range/monotonicity");
   previous_gain=gain;
  end
  velocity=48;#1;if(gain!=60) $fatal(1,"soft gain");
  velocity=88;#1;if(gain!=128) $fatal(1,"medium gain");
  velocity=127;#1;if(gain!=206) $fatal(1,"hard gain");
  for(n=0;n<3;n=n+1) begin
   previous_energy=0;
   for(level=0;level<3;level=level+1) begin
    rst_n=0;ev=0;pv=0;note=48+n*12;
    velocity=level==0 ? 48 : level==1 ? 88 : 127;
    repeat(5) @(negedge clk);rst_n=1;wait(ready);
    parameter_event(`PARAM_VOLUME,32767);
    wait(dut.volume==dut.volume_target);
    parameter_event(`PARAM_INSTRUMENT,1);
    @(negedge clk);ev=1;@(negedge clk);ev=0;
    energy=0;samples=0;
    while(samples<512) begin
     @(negedge clk);
     if(eo || po || overload) $fatal(1,"guitar overflow");
     if(valid) begin
      if((^left)===1'bx || left!==right) $fatal(1,"invalid guitar PCM");
      magnitude=$signed(left);if(magnitude<0) magnitude=-magnitude;
      energy=energy+magnitude;samples=samples+1;
     end
    end
    if(energy==0 || (level!=0 && energy*100<previous_energy*120))
     $fatal(1,"insufficient guitar dynamics note=%0d velocity=%0d energy=%0d previous=%0d",
       note,velocity,energy,previous_energy);
    $display("guitar note=%0d velocity=%0d gain=%0d energy=%0d",note,velocity,gain,energy);
    previous_energy=energy;
   end
  end
  $display("PASS guitar gain bounds, three registers, soft/medium/hard PCM dynamics and no overload");
  $finish;
 end
 initial begin #30000000;$fatal(1,"guitar dynamics timeout");end
endmodule

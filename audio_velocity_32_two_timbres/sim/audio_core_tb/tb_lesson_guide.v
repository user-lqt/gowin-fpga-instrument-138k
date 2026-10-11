`timescale 1ns/1ps
module tb_lesson_guide;
 reg clk=0,rst_n=0,song_mode=0,toggle=0,song=0;
 reg [23:0] keys=0;
 wire running;wire [4:0] position;wire [1:0] beat;wire [23:0] guides;
 always #5 clk=~clk;
 lesson_guide dut(.clk(clk),.rst_n(rst_n),.song_mode(song_mode),.toggle(toggle),
  .song(song),.keys(keys),.running(running),.position(position),.beat(beat),.guide_keys(guides));
 integer score[0:13];integer i;
 task cycles;begin repeat(3) @(negedge clk);end endtask
 task strike;input integer k;begin keys=24'd1<<k;cycles;keys=0;cycles;end endtask
 task restart;begin toggle=1;cycles;toggle=0;cycles;end endtask
 initial begin
  score[0]=0;score[1]=0;score[2]=7;score[3]=7;score[4]=9;score[5]=9;score[6]=7;
  score[7]=5;score[8]=5;score[9]=4;score[10]=4;score[11]=2;score[12]=2;score[13]=0;
  cycles;rst_n=1;cycles;
  if(guides!==0 || running) $fatal(1,"outside SONG");
  keys=1;cycles;song_mode=1;cycles;
  if(guides!==1 || position!=0 || !running) $fatal(1,"entry or held key");
  repeat(100) @(negedge clk);
  if(position!=0) $fatal(1,"advanced without new press");
  keys=0;cycles;strike(23);
  if(position!=0) $fatal(1,"wrong key advanced");
  keys=1;cycles;
  if(position!=1 || guides!==1) $fatal(1,"first C");
  cycles;if(position!=1) $fatal(1,"repeat note consumed held key");
  keys=0;cycles;strike(0);
  if(position!=2 || guides!==(24'd1<<7)) $fatal(1,"second C");
  song_mode=0;#1;if(guides!==0) $fatal(1,"exit not gated");cycles;
  strike(7);song_mode=1;cycles;
  if(position!=0 || guides!==1) $fatal(1,"reentry did not restart");
  for(i=0;i<14;i=i+1) begin
   if(position!=i || guides!==(24'd1<<score[i])) $fatal(1,"score step %0d",i);
   strike(score[i]);
  end
  if(running || guides!==0 || position!=14) $fatal(1,"completion");
  strike(0);if(running) $fatal(1,"restarted unexpectedly");
  restart;if(position!=0 || guides!==1) $fatal(1,"long restart");
  song=1;cycles;if(position!=0 || guides!==(24'd1<<4)) $fatal(1,"song change");
  song=0;cycles;if(guides!==1) $fatal(1,"song back");
  song_mode=0;cycles;song_mode=1;cycles;
  if(guides!==1 || position!=0) $fatal(1,"second reentry");
  rst_n=0;cycles;if(guides!==0) $fatal(1,"reset");rst_n=1;cycles;
  if(guides!==1 || !running) $fatal(1,"reset in SONG");
  $display("PASS: score order, correct/wrong/held/repeated keys, no auto advance, completion, restart, mode exit/reentry");
  $finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule

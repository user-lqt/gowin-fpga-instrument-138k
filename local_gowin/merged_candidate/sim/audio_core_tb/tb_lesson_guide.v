`timescale 1ns/1ps
module tb_lesson_guide;
 reg clk=0,rst_n=0,song_mode=0,select_valid=0;
 reg [1:0] select_song=0;
 reg [23:0] keys=0;
 wire running,complete,unavailable;
 wire [1:0] song,beat;
 wire [9:0] position,total;
 wire [23:0] guides;
 always #5 clk=~clk;
 lesson_guide dut(.clk(clk),.rst_n(rst_n),.song_mode(song_mode),
  .sample_tick(1'b0),.rhythm_enabled(1'b0),.local_start(1'b0),.local_song(2'd1),.tempo(8'd120),
  .user_length(8'd0),.user_key(8'd0),.user_duration(8'd1),.user_ready(1'b0),
  .select_valid(select_valid),.select_song(select_song),.keys(keys),
  .running(running),.complete(complete),.unavailable(unavailable),.song(song),
  .position(position),.total(total),.beat(beat),.guide_keys(guides));
 task cycles;begin repeat(3) @(negedge clk);end endtask
 task choose;input [1:0] id;begin
  @(negedge clk);select_song=id;select_valid=1;
  @(negedge clk);select_valid=0;cycles;
 end endtask
 integer p,k,target;
 reg [7:0] melody[0:41];
 reg [23:0] mask;
 initial begin
  cycles;rst_n=1;cycles;
  choose(1);song_mode=1;cycles;
  if(running || guides!=0 || song!=0) $fatal(1,"outside command retained");
  choose(1);
  if(!running || total!=54 || guides!=(24'd1<<4)) $fatal(1,"Jasmine start");
  keys=24'd1;cycles;
  if(position!=0) $fatal(1,"wrong key advanced");
  keys=0;cycles;
  for(p=0;p<54;p=p+1) begin
   mask=guides;
   if(mask==0 || (mask & (mask-1))!=0 || mask[5]) $fatal(1,"bad guide or K6");
   keys=mask;cycles;
   if(position!=p+1) $fatal(1,"step %0d",p);
   cycles;if(position!=p+1) $fatal(1,"held key repeated");
   keys=0;cycles;
  end
  if(running || !complete || guides!=24'hFFFFFF) $fatal(1,"completion lights");
  // Independent physical-key reference for G-major Twinkle Twinkle.
  {melody[0],melody[1],melody[2],melody[3],melody[4],melody[5],melody[6]}={8'd8,8'd8,8'd15,8'd15,8'd17,8'd17,8'd15};
  {melody[7],melody[8],melody[9],melody[10],melody[11],melody[12],melody[13]}={8'd13,8'd13,8'd12,8'd12,8'd10,8'd10,8'd8};
  {melody[14],melody[15],melody[16],melody[17],melody[18],melody[19],melody[20]}={8'd15,8'd15,8'd13,8'd13,8'd12,8'd12,8'd10};
  for(p=0;p<7;p=p+1) begin melody[21+p]=melody[14+p];melody[28+p]=melody[p];melody[35+p]=melody[7+p];end
  choose(2);
  if(complete || !running || unavailable || song!=2 || total!=42 || guides!=(24'd1<<7)) $fatal(1,"Twinkle selection");
  for(p=0;p<42;p=p+1) begin
   mask=guides;
   if(mask!=(24'd1<<(melody[p]-1)) || mask[5]) $fatal(1,"Twinkle target %0d",p);
   keys=mask;cycles;
   if(position!=p+1) $fatal(1,"Fingerprint step %0d",p);
   cycles;if(position!=p+1) $fatal(1,"Fingerprint held key advanced");
   keys=0;cycles;
  end
  if(running || !complete || guides!=24'hFFFFFF) $fatal(1,"Fingerprint completion");
  choose(3);if(!unavailable || song!=3) $fatal(1,"slot3");
  choose(1);if(!running || position!=0) $fatal(1,"restart after completion");
  choose(0);if(running || guides!=0 || complete) $fatal(1,"stop guide");
  choose(1);
  song_mode=0;#1;if(guides!=0) $fatal(1,"exit gating");cycles;
  song_mode=1;cycles;
  if(running || complete || song!=0 || guides!=0) $fatal(1,"re-entry must wait");
  choose(1);rst_n=0;cycles;rst_n=1;cycles;
  if(running || guides!=0) $fatal(1,"reset must wait");
  $display("PASS: BLE selection, Jasmine 54 and Twinkle 42 steps, no K6, wrong/held keys, completion, stop, switching, exit/reentry/reset, slot3 unavailable");
  $finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule

`timescale 1ns/1ps
`include "event_defs.vh"
module tb_ble_song_uart;
 reg clk=0,rst_n=0,rx=1;
 always #5 clk=~clk;
 wire ev,sv,err;wire [1:0] et,si;wire [6:0] note;wire [7:0] vel;
 ble_uart_rx #(.CLK_HZ(1000000),.BAUD(100000)) dut(
  .clk(clk),.rst_n(rst_n),.uart_rx(rx),.event_valid(ev),.event_type(et),
  .note_id(note),.velocity(vel),.frame_error(err),.song_valid(sv),.song_id(si));
 integer events=0,selections=0,errors=0;
 reg [1:0] last_song;
 always @(negedge clk) begin
  if(ev) events=events+1;
  if(sv) begin selections=selections+1;last_song=si;end
  if(err) errors=errors+1;
 end
 task sendbyte;input [7:0] value;integer b;begin
  @(negedge clk);rx=0;repeat(10) @(negedge clk);
  for(b=0;b<8;b=b+1) begin rx=value[b];repeat(10) @(negedge clk);end
  rx=1;repeat(12) @(negedge clk);
 end endtask
 task frame;input [7:0] cmd,n,v,sum;begin
  sendbyte(8'hA5);sendbyte(cmd);sendbyte(n);sendbyte(v);sendbyte(sum);
  repeat(10) @(negedge clk);
 end endtask
 initial begin
  repeat(5) @(negedge clk);rst_n=1;
  frame('hB0,1,0,'h14);if(selections!=1 || last_song!=1 || events!=0) $fatal(1,"song1");
  frame('hB0,2,0,'h17);if(selections!=2 || last_song!=2) $fatal(1,"song2");
  frame('hB0,3,0,'h16);if(selections!=3 || last_song!=3) $fatal(1,"song3");
  frame('hB0,4,0,'h11);if(selections!=3 || errors!=1) $fatal(1,"invalid ID");
  frame('hB0,1,1,'h15);if(selections!=3 || errors!=2) $fatal(1,"invalid payload");
  frame('hB0,1,0,0);if(selections!=3 || errors!=3) $fatal(1,"bad checksum");
  frame('h90,'h3C,'h64,'h6D);
  if(events!=1 || et!=`EVENT_NOTE_ON || note!=60 || vel!=100) $fatal(1,"note on regression");
  frame('h80,'h3C,0,'h19);
  if(events!=2 || et!=`EVENT_NOTE_OFF || vel!=0) $fatal(1,"note off regression");
  $display("PASS: actual UART bits, all song commands, rejection, note on/off regression");$finish;
 end
 initial begin #200000;$fatal(1,"timeout");end
endmodule

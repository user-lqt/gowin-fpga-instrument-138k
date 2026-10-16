`timescale 1ns/1ps
`include "event_defs.vh"
module tb_extensions;
 reg clk=0,rst=0,cv=0,tick=0,mode=0,local_start=0;
 always #5 clk=~clk;
 reg [7:0] cmd=0,a=0,b=0;
 reg [23:0] keys=0;
 reg kv=0;reg [1:0] kt=1;reg [6:0] kn=60;reg [7:0] vel=127;
 wire mv;wire [1:0] mt;wire [6:0] mn;wire [7:0] mvel;
 wire [7:0] sk,sd,sl,tempo;wire sr,rhythm,tv,rec,ro,dumping,qo,tx;
 wire [9:0] rc;
 wire [6:0] sa;
 wire running,complete,unavailable,count_in,flash;
 wire [1:0] song,beat;wire [9:0] pos,total,good,miss;
 wire [2:0] grade;wire [23:0] guides;
 reg sv=0;reg [1:0] selection=3;
 wire ev,ov;wire [1:0] et;wire [6:0] en;wire [7:0] evelocity;
 reg bv=0;reg [1:0] bt=1;reg [6:0] bn=72;
 performance_event_merge merge(.clk(clk),.rst_n(rst),.a_valid(mv),.a_type(mt),.a_note(mn),.a_velocity(mvel),
 .b_valid(bv),.b_type(bt),.b_note(bn),.b_velocity(8'd100),.valid(ev),.kind(et),.note(en),.velocity(evelocity),.overflow(ov));
 instrument_link #(.CLK_HZ(1000000),.BAUD(100000)) dut(.clk(clk),.rst_n(rst),.sample_tick(tick),
 .command_valid(cv),.command(cmd),.a(a),.b(b),.keys(keys),
 .keyboard_valid(kv),.keyboard_type(kt),.keyboard_note(kn),.keyboard_velocity(vel),
 .mapped_valid(mv),.mapped_type(mt),.mapped_note(mn),.mapped_velocity(mvel),
 .record_valid(ev),.record_type(et),.record_note(en),.record_velocity(evelocity),
 .lesson_running(running),.song_mode(mode),.score_address(sa),.score_key(sk),.score_duration(sd),.score_length(sl),.score_ready(sr),
 .rhythm_enabled(rhythm),.remote_tempo(tempo),.tempo_valid(tv),.recording(rec),.record_count(rc),.record_overflow(ro),.dumping(dumping),.reply_overflow(qo),.tx(tx));
 lesson_guide lesson(.clk(clk),.rst_n(rst),.song_mode(mode),
 .select_valid(sv || (cv && cmd==8'hB3 && a==0 && b==0)),.select_song(sv ? selection : 2'd0),
 .sample_tick(tick),.rhythm_enabled(rhythm),.local_start(local_start),.local_song(2'd3),.tempo(8'd120),
 .user_ready(sr),.user_length(sl),.user_key(sk),.user_duration(sd),.score_address(sa),
 .count_in(count_in),.beat_flash(flash),.timing_grade(grade),.correct_count(good),.miss_count(miss),
 .keys(keys),.running(running),.complete(complete),.unavailable(unavailable),.song(song),.position(pos),.total(total),.beat(beat),.guide_keys(guides));
 reg [7:0] bytes[0:11];reg [7:0] value,check;
 integer index=0,bitno,acknowledgements=0,record_packets=0,end_packets=0;
 reg [7:0] ackcmd,ackstatus;
 reg [31:0] last_time=0;
 // Decode actual UART pin, not internal packet registers.
 initial forever begin
 @(negedge tx);repeat(15) @(posedge clk);#1;
 for(bitno=0;bitno<8;bitno=bitno+1) begin
 value[bitno]=tx;repeat(10) @(posedge clk);#1;
 end
 if(tx!==1) $fatal(1,"bad UART stop");
 bytes[index]=value;
 if(index==11) begin
 check=0;for(index=0;index<12;index=index+1) check=check^bytes[index];
 if(check!=0 || bytes[0]!=8'hA6) $fatal(1,"reply framing/checksum");
 if(bytes[1]==8'hF0) begin ackcmd=bytes[2];ackstatus=bytes[3];acknowledgements=acknowledgements+1;end
 else if(bytes[1]==8'hE0) begin
 if(bytes[9]!=record_packets || bytes[10]!=0) $fatal(1,"dump index/order");
 if(record_packets==0 && (bytes[3]!=84 || bytes[2]!=1)) $fatal(1,"recorded mapped note");
 if(record_packets==1 && (bytes[3]!=72 || bytes[2]!=1)) $fatal(1,"simultaneous BLE note lost");
 if(record_packets==2 && bytes[2]!=2) $fatal(1,"missing NOTE_OFF");
 value=0;
 if({bytes[8],bytes[7],bytes[6],bytes[5]}<last_time) $fatal(1,"timestamps out of order");
 last_time={bytes[8],bytes[7],bytes[6],bytes[5]};record_packets=record_packets+1;
 end else if(bytes[1]==8'hE1) begin
 if(bytes[2]!=3 || bytes[3]!=0 || bytes[4]!=0) $fatal(1,"dump end count");end_packets=end_packets+1;
 end
 index=0;
 end else index=index+1;
 end
 task command;input [7:0] c,x,y,result;integer before_ack;begin
 before_ack=acknowledgements;
 @(negedge clk);cmd=c;a=x;b=y;cv=1;
 @(negedge clk);cv=0;
 wait(acknowledgements>before_ack);@(negedge clk);
 if(ackcmd!=c || ackstatus!=result) $fatal(1,"cmd %h result %h expected %h",c,ackstatus,result);
 end endtask
 task keyevent;input [1:0] kind;begin
 @(negedge clk);kv=1;kt=kind;
 @(negedge clk);kv=0;repeat(5) @(negedge clk);
 end endtask
 initial begin
 repeat(4) @(negedge clk);rst=1;
 command('hB0,1,0,3); // outside SONG
 command('hC0,3,0,0);
 command('hC1,1,1,0);
 command('hC1,6,1,2); // K6 forbidden
 command('hC2,0,0,4); // incomplete cannot publish
 command('hC1,0,2,0); // rest
 command('hC1,3,1,0);command('hC2,0,0,0);
 if(!sr || sl!=3) $fatal(1,"score publication");
 command('hD0,1,61,2); // duplicate mapping forbidden
 command('hD0,1,84,0);
 command('hE0,0,0,0);tick=1;
 // Queue A and B on the same clock by aligning B with mapped_valid.
 @(negedge clk);kv=1;kt=1;
 @(negedge clk);kv=0;bv=1;
 @(negedge clk);bv=0;
 repeat(300) @(negedge clk);
 keys=1;command('hD0,1,85,3);keys=0;
 keyevent(2);command('hE1,0,0,0);
 if(rc!=3 || ro || ov) $fatal(1,"event count/overflow");
 command('hE2,0,0,0);wait(end_packets==1);
 if(record_packets!=3 || last_time==0) $fatal(1,"record transfer");
 command('hD1,0,0,0);
 command('hB1,1,0,0);mode=1;repeat(4) @(negedge clk);
 local_start=1;@(negedge clk);local_start=0;
 repeat(3) @(negedge clk);
 if(!running || !count_in || total!=3) $fatal(1,"offline start/count-in");
 command('hC0,1,0,3);
 keys=1;repeat(3) @(negedge clk);keys=0;
 if(grade!=1) $fatal(1,"early grade");
 wait(!count_in);@(negedge clk);keys=1;repeat(3) @(negedge clk);keys=0;
 if(good!=1 || grade!=2) $fatal(1,"onset grade");
 wait(pos==1);#1;if(guides!=0) $fatal(1,"rest illuminated");
 wait(complete);@(negedge clk);
 if(miss!=1 || guides!=24'hFFFFFF) $fatal(1,"miss/completion");
 mode=0;repeat(3) @(negedge clk);mode=1;repeat(3) @(negedge clk);
 if(running || complete || guides!=0) $fatal(1,"re-entry reused song");
 // Switch live rhythm -> free: restart, then hold the target indefinitely.
 local_start=1;@(negedge clk);local_start=0;repeat(3) @(negedge clk);
 if(!count_in) $fatal(1,"rhythm not retained");
 command('hB1,0,0,0);repeat(3) @(negedge clk);
 if(rhythm || count_in || pos!=0 || !running) $fatal(1,"switch to free");
 repeat(30000) @(negedge clk);
 if(pos!=0 || complete) $fatal(1,"free advanced without key");
 keys=1;repeat(3) @(negedge clk);keys=0;
 repeat(3) @(negedge clk);
 if(pos!=2) $fatal(1,"free target/rest advance");
 repeat(30000) @(negedge clk);
 if(pos!=2) $fatal(1,"free timeout advanced target");
 command('hB1,1,0,0);repeat(3) @(negedge clk);
 if(!rhythm || !count_in || pos!=0) $fatal(1,"switch back to rhythm");
 command('hB2,80,0,0);if(tempo!=80) $fatal(1,"live tempo");
 command('hB3,1,0,2);if(!running) $fatal(1,"invalid stop affected guide");
 command('hB3,0,0,0);
 if(running || guides!=0) $fatal(1,"upload stop did not clear guide");
 command('hC0,2,0,0);command('hC1,8,2,0);command('hC1,10,2,0);command('hC2,0,0,0);
 command('hB1,0,0,0);
 @(negedge clk);sv=1;selection=3;@(negedge clk);sv=0;repeat(4) @(negedge clk);
 if(!running || total!=2 || guides!=(24'd1<<7)) $fatal(1,"new downloaded score first LED");
 keys=24'd1<<7;repeat(4) @(negedge clk);keys=0;repeat(4) @(negedge clk);
 if(pos!=1 || guides!=(24'd1<<9)) $fatal(1,"new downloaded score next LED");
 if(qo) $fatal(1,"reply overflow");
 // Capacity is bounded; reject dump while recording, then stop on overflow.
 command('hE0,0,0,0);command('hE2,0,0,3);
 repeat(513) keyevent(1);
 if(rec || !ro || rc!=512) $fatal(1,"record capacity");
 rst=0;repeat(3) @(negedge clk);rst=1;repeat(3) @(negedge clk);
 if(sr || rec || ro || rc!=0) $fatal(1,"volatile reset");
 $display("PASS: offline/count-in/rhythm/rests, score transaction/rejection, mapping, simultaneous events, timestamped recording and actual UART dump");$finish;
 end
 initial begin #10000000;$fatal(1,"timeout");end
endmodule

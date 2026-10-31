`timescale 1ns/1ps
module tb_acceptance_sweep;
 parameter integer VOICES=64;
 reg clk=0,rst=0,tick=0,toggle=0;
 reg [6:0] selection=0;
 always #5 clk=~clk;
 always @(posedge clk) tick<=!tick;
 wire active,stable,ev;
 wire [1:0] kind;
 wire [6:0] note,applied,expected;
 wire [7:0] velocity;
 polyphony_test #(.VOICES(VOICES),.SELECT_SAMPLES(3),.SETTLE_SAMPLES(3)) dut(
 .clk(clk),.rst_n(rst),.sample_tick(tick),.toggle(toggle),.selection(selection),
 .keyboard_valid(1'b0),.keyboard_type(2'd0),.keyboard_note(7'd0),
 .keyboard_velocity(8'd0),.keys(24'd0),.active(active),.ready(stable),
 .applied_selection(applied),.expected_count(expected),
 .event_valid(ev),.event_type(kind),.note_id(note),.velocity(velocity));
 reg [VOICES-1:0] observed=0,wanted;
 integer i,k,wanted_count,event_count=0;
 always @(negedge clk) if(ev) begin
 event_count=event_count+1;
 if(note>=48 && note<48+VOICES) begin
 if(kind==1) observed[note-48]=1;
 if(kind==2) observed[note-48]=0;
 end
 end
 task action;
 begin @(negedge clk);toggle=1;@(negedge clk);toggle=0;end endtask
 initial begin
 repeat(4) @(negedge clk);rst=1;action;
 wait(stable);@(negedge clk);
 if(observed!={VOICES{1'b1}}) $fatal(1,"initial all");
 for(i=1;i<=VOICES+4;i=i+1) begin
 @(negedge clk);selection=i;
 #1;if(stable) $fatal(1,"pending selection reported stable");
 wait(stable && applied==i);@(negedge clk);
 wanted=0;wanted_count=0;
 for(k=0;k<VOICES;k=k+1) begin
 if((i<=4 && k/(VOICES/4)==i-1) || (i>=5 && k!=i-5)) begin
 wanted[k]=1;wanted_count=wanted_count+1;
 end
 end
 if(observed!==wanted || expected!=wanted_count)
 $fatal(1,"selection %0d mask %h wanted %h count %0d",i,observed,wanted,expected);
 end
 selection=0;wait(stable && applied==0);@(negedge clk);
 if(observed!={VOICES{1'b1}} || expected!=VOICES) $fatal(1,"restored ALL");
 // Changes faster than debounce must not apply an intermediate selection.
 selection=1;repeat(2) @(negedge clk);selection=2;
 repeat(2) @(negedge clk);selection=3;
 wait(stable && applied==3);@(negedge clk);
 if(expected!=VOICES/4) $fatal(1,"rapid selection settle");
 action;wait(!active);@(negedge clk);
 if(observed!=0 || expected!=0) $fatal(1,"stop all cleanup");
 $display("PASS %0d voices: ALL, every GROUP and every MUTE, rapid selection, stop (%0d events)",VOICES,event_count);
 $finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule

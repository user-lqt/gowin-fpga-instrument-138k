`timescale 1ns/1ps
module tb_acceptance_default_timing;
 reg clk=0,rst_n=0,tick=0,toggle=0;
 reg [23:0] keys=0;
 always #5 clk=~clk;
 always @(posedge clk) tick<=!tick;
 wire active,ready;
 wire [6:0] applied,expected,note;
 wire valid;
 wire [1:0] kind;
 wire [7:0] velocity;
 integer frames=0,started;
 always @(posedge clk) if(rst_n && tick) frames<=frames+1;
 polyphony_test dut(
 .clk(clk),.rst_n(rst_n),.sample_tick(tick),.toggle(toggle),.selection(7'd0),
 .keyboard_valid(1'b0),.keyboard_type(2'd0),.keyboard_note(7'd0),
 .keyboard_velocity(8'd0),.keys(keys),.active(active),.ready(ready),
 .applied_selection(applied),.expected_count(expected),
 .event_valid(valid),.event_type(kind),.note_id(note),.velocity(velocity));
 task action;
 begin @(negedge clk);toggle=1;@(negedge clk);toggle=0;end
 endtask
 initial begin
 repeat(4) @(negedge clk);rst_n=1;
 started=frames;action;wait(ready);@(negedge clk);
 if(frames-started<128+128+6400+32+6400)
 $fatal(1,"default startup settled too early");
 if(expected!=32) $fatal(1,"default startup count");
 keys=1;started=frames;action;
 wait(dut.state==7);@(negedge clk);
 if(frames-started<128+128+6400)
 $fatal(1,"normal route restored before FX delay drained");
 repeat(20) @(negedge clk);
 if(!active || ready) $fatal(1,"held key did not block normal restore");
 keys=0;wait(!active);
 $display("PASS default 6400-frame startup/exit waits and held-key restore");
 $finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule

`timescale 1ns/1ps
module tb_scan_debounce15;
 reg clk=0,rst_n=0;
 always #5 clk=~clk;
 reg [47:0] contacts=0;
 reg [5:0] columns;
 wire [7:0] rows;
 wire [23:0] state;
 wire valid;
 wire [1:0] kind;
 wire [6:0] note;
 integer r,ons=0,offs=0,cycle=0,last_frame=-1,frames=0;
 keyboard_24_input #(.ROW_CYCLES(307),.DEBOUNCE_FRAMES(15),
 .RELEASE_DEBOUNCE_FRAMES(64),.AB_MAX_FRAMES(5004),.BASE_NOTE(60)) dut(
 .clk(clk),.rst_n(rst_n),.col_in(columns),.row_out(rows),
 .key_state(state),.event_valid(valid),.event_type(kind),.note_id(note));
 always @* begin
 columns=6'h3f;
 for(r=0;r<8;r=r+1)
 if(rows[r]===1'b0) columns=~contacts[r*6+:6];
 end
 always @(posedge clk) begin
 cycle=cycle+1;
 if(dut.scan_valid) begin
 if(last_frame>=0 && cycle-last_frame!=2456) $fatal(1,"Scanner cadence changed");
 last_frame=cycle;frames=frames+1;
 end
 if(valid) begin
 if(note!=60) $fatal(1,"Wrong note mapping");
 if(kind==1) ons=ons+1;
 else if(kind==2) offs=offs+1;
 end
 end
 task wait_frames(input integer n);
 integer j;
 begin
 for(j=0;j<n;j=j+1) begin
 @(negedge clk);while(!dut.scan_valid) @(negedge clk);
 @(negedge clk);
 end
 end endtask
 initial begin
 repeat(4) @(negedge clk);rst_n=1;
 wait_frames(3);
 contacts=48'h41;wait_frames(10);contacts=0;wait_frames(70);
 if(ons || offs) $fatal(1,"Physical scanned short glitch caused note");
 contacts=1;wait_frames(5);contacts=48'h41;wait_frames(22);
 if(ons!=1 || state!=1) $fatal(1,"Physical scanner stable press failed");
 wait_frames(30);if(ons!=1) $fatal(1,"Physical hold retriggered");
 contacts=0;wait_frames(55);
 if(offs || state!=1) $fatal(1,"Physical early release");
 wait_frames(20);if(offs!=1 || state) $fatal(1,"Physical release failed");
 $display("PASS physical8x6 scanner307 cycles/row2456 cycles/frame,15/64 qualification,NOTE_ON60 and NOTE_OFF");
 $finish;
 end
 initial begin #20000000;$fatal(1,"Timeout");end
endmodule

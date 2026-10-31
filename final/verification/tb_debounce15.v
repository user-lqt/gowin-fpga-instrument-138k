`timescale 1ns/1ps
module tb_debounce15;
 reg clk=0,rst_n=0,scan_valid=0;
 always #5 clk=~clk;
 reg [47:0] contacts=0;
 wire [23:0] state15,state40;
 wire valid15,valid40;
 wire [1:0] kind15,kind40;
 wire [4:0] key15,key40;
 wire [7:0] velocity15,velocity40;
 integer ons15=0,offs15=0,ons40=0,offs40=0,i;
 reg [7:0] velocities15[0:23],velocities40[0:23];
 keyboard_24_dual #(.DEBOUNCE_FRAMES(15),.RELEASE_DEBOUNCE_FRAMES(64),
 .AB_MAX_FRAMES(5004)) new_core(.clk(clk),.rst_n(rst_n),
 .scan_valid(scan_valid),.contact_raw(contacts),.key_state(state15),
 .event_valid(valid15),.event_type(kind15),.key_id(key15),.velocity(velocity15));
 keyboard_24_dual #(.DEBOUNCE_FRAMES(40),.RELEASE_DEBOUNCE_FRAMES(64),
 .AB_MAX_FRAMES(5004)) old_core(.clk(clk),.rst_n(rst_n),
 .scan_valid(scan_valid),.contact_raw(contacts),.key_state(state40),
 .event_valid(valid40),.event_type(kind40),.key_id(key40),.velocity(velocity40));
 always @(posedge clk) begin
 if(valid15) begin
 if(kind15==1) begin ons15=ons15+1;velocities15[key15]=velocity15;end
 else if(kind15==2) offs15=offs15+1;
 else $fatal(1,"Unexpected new event");
 end
 if(valid40) begin
 if(kind40==1) begin ons40=ons40+1;velocities40[key40]=velocity40;end
 else if(kind40==2) offs40=offs40+1;
 else $fatal(1,"Unexpected old event");
 end
 end
 task frame(input [47:0] value);
 begin
 @(negedge clk);contacts=value;scan_valid=1;
 @(negedge clk);scan_valid=0;
 repeat(8000) @(negedge clk);
 end endtask
 initial begin
 repeat(4) @(negedge clk);rst_n=1;
 repeat(14) frame(48'hffffffffffff);
 repeat(66) frame(0);
 if(ons15 || offs15 || ons40 || offs40) $fatal(1,"14-frame glitch caused event");
 // Preserve raw A->B interval and calibrated velocity for all24 keys.
 repeat(3) frame(48'h03f03f03f03f);
 repeat(14) frame(48'hffffffffffff);
 if(state15 || state40 || ons15 || ons40) $fatal(1,"Early press");
 frame(48'hffffffffffff);
 if(state15!=24'hffffff || ons15!=24 || state40 || ons40)
 $fatal(1,"Press must qualify at exactly15 consecutive frames");
 repeat(25) frame(48'hffffffffffff);
 if(state40!=24'hffffff || ons40!=24) $fatal(1,"40-frame counterexample mismatch");
 for(i=0;i<24;i=i+1)
 if(velocities15[i]!==velocities40[i]) $fatal(1,"Velocity changed key=%0d",i);
 repeat(10) frame(48'hffffffffffff);
 if(ons15!=24 || ons40!=24) $fatal(1,"Held keys repeated NOTE_ON");
 repeat(63) frame(0);
 if(state15!=24'hffffff || state40!=24'hffffff || offs15 || offs40)
 $fatal(1,"Release happened before64 frames");
 frame(48'hffffffffffff);
 repeat(63) frame(0);
 if(offs15 || offs40) $fatal(1,"Release bounce did not reset qualification");
 frame(0);
 if(state15 || state40 || offs15!=24 || offs40!=24)
 $fatal(1,"64th release frame must serialize24 NOTE_OFF events");
 repeat(4) frame(0);
 repeat(15) frame(48'hffffffffffff);
 if(ons15!=48 || offs15!=24) $fatal(1,"Repress after release failed");
 repeat(64) frame(0);
 if(offs15!=48 || state15) $fatal(1,"Final release failed");
 $display("PASS exact15/64 debounce,14-frame glitch,release bounce,hold/repress,24-key events,unchanged raw-travel velocities vs40");
 $finish;
 end
 initial begin #60000000;$fatal(1,"Timeout");end
endmodule

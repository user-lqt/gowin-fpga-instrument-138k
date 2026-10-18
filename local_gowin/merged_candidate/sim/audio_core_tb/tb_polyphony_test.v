`timescale 1ns/1ps
module tb_polyphony_test;
 reg clk=0,rst=0,tick=0,toggle=0,kv=0;
 reg [23:0] keys=0;
 always #5 clk=~clk;
 integer div=0;
 always @(posedge clk) begin
 if(!rst) begin div<=0;tick<=0;end
 else begin div<=div==255 ? 0 : div+1;tick<=div==255;end end
 wire active,ev;wire [1:0] kind;wire [6:0] note;wire [7:0] velocity;
 polyphony_test source(.clk(clk),.rst_n(rst),.sample_tick(tick),.toggle(toggle),
 .keyboard_valid(kv),.keyboard_type(2'd1),.keyboard_note(7'd90),.keyboard_velocity(8'd64),.keys(keys),
 .active(active),.event_valid(ev),.event_type(kind),.note_id(note),.velocity(velocity));
 wire valid,ready,overflow,po,overload;wire [5:0] count;
 wire signed [23:0] left,right;
 wire [127:0] spectrum;
 audio_visualizer analyzer(.audio_clk(clk),.audio_rst_n(rst),.valid(valid),
 .sample(left[23:8]),.spectrum(spectrum),.pixel_clk(clk),.pixel_rst_n(rst),
 .frame_start(1'b0),.xy_address(14'd0));
 audio_core #(.ENABLE_GUITAR(0),.RELEASE_SAMPLES(64)) core(
 .clk(clk),.rst_n(rst),.sample_tick(tick),.event_valid(ev),.event_type(kind),.note_id(note),.velocity(velocity),
 .param_valid(1'b0),.param_id(4'd0),.param_value(16'd0),.audio_core_valid(valid),.audio_left(left),.audio_right(right),
 .active_voice_count(count),.engine_ready(ready),.overload_flag(overload),.event_overflow(overflow),.param_overflow(po));
 integer ons=0,offs=0,frames=0;
 always @(posedge clk) if(rst) begin
 if(ev && kind==1 && active) begin
 if(note!=48+ons) $fatal(1,"test note order");ons=ons+1;end
 if(ev && kind==2) offs=offs+1;
 if(valid) begin frames=frames+1;
 if(overflow || po || (^left)===1'bx || left!==right) $fatal(1,"audio fault");end
 end
 task action;begin @(negedge clk);toggle=1;@(negedge clk);toggle=0;end endtask
 task samples;input integer amount;integer i;
 begin for(i=0;i<amount;i=i+1) begin @(posedge valid);@(negedge clk);end end endtask
 initial begin
 repeat(4) @(negedge clk);rst=1;wait(ready);
 action;kv=1;samples(1200);kv=0;
 if(count!=32 || ons!=32 || offs!=128) $fatal(1,"not real 32 voices: %d",count);
 if((^spectrum)===1'bx || spectrum==0) $fatal(1,"32-voice mixed spectrum empty");
 keys=1;action;samples(400);
 if(count!=0 || left!=0 || !active || offs!=256) $fatal(1,"exit cleanup");
 samples(1100);
 if(spectrum!==0) $fatal(1,"mixed spectrum retained after release and silent windows");
 keys=0;samples(3);if(active) $fatal(1,"keyboard resume");
 @(negedge clk);kv=1;@(negedge clk);kv=0;samples(3);
 if(count!=1) $fatal(1,"normal input lost");
 $display("PASS real 32 voices, mixed-output DFT, silence, ordered notes, keyboard isolation, exit release, resume %d frames",frames);$finish;
 end
 initial begin #10000000;$fatal(1,"timeout");end
endmodule

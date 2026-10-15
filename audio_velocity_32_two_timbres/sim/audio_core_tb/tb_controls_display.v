`timescale 1ns/1ps
`include "event_defs.vh"
module tb_controls_display;
 reg clk=0,rst=0,sw=1;always #5 clk=~clk;
 wire [2:0] menu;wire [6:0] glide,fx;wire enabled,ready,song,toggle,valid,test_toggle;
 wire [7:0] tempo;wire [3:0] id,inspect_band;wire [1:0] local_song;wire [15:0] payload;
 encoder_b_control #(.FILTER_CYCLES(2),.BUTTON_CYCLES(2),.LONG_CYCLES(30)) dut(
 .clk(clk),.rst_n(rst),.enc_a(1'b1),.enc_b(1'b1),.enc_sw_n(sw),.menu(menu),
 .input_ready(ready),.glide_value(glide),.effect_value(fx),.glide_enabled(enabled),
 .tempo(tempo),.song_select(song),.local_song(local_song),.inspect_band(inspect_band),.lesson_toggle(toggle),.test_toggle(test_toggle),.param_valid(valid),.param_id(id),.param_value(payload));
 integer tests=0;
 always @(posedge clk) if(test_toggle) tests=tests+1;
 integer last_glide=-1,last_fx=-1;
 always @(posedge clk) begin #1;if(valid) begin
 if(id==`PARAM_GLIDE) last_glide=payload;
 if(id==`PARAM_EFFECT_MIX) last_fx=payload;
 end end
 task button;input integer duration;
 begin @(negedge clk);sw=0;repeat(duration) @(negedge clk);sw=1;repeat(12) @(negedge clk);end endtask
 task rotate;input direction;
 begin @(negedge clk);force dut.up=direction;force dut.down=!direction;
 @(negedge clk);release dut.up;release dut.down;@(negedge clk);end endtask
 initial begin
 repeat(4) @(negedge clk);rst=1;repeat(15) @(negedge clk);
 if(last_glide!=0 || last_fx!=0 || enabled || glide!=15) $fatal(1,"startup");
 button(45);if(!enabled || last_glide!=14400 || menu!=0) $fatal(1,"glide long on");
 rotate(1);if(last_glide!=15360 || glide!=16) $fatal(1,"time units");
 button(45);if(enabled || last_glide!=0 || menu!=0) $fatal(1,"glide bypass");
 button(10);if(menu!=1) $fatal(1,"short page");
 rotate(1);if(fx!=4 || last_fx!=2064) $fatal(1,"fx mapping");
 button(45);if(fx!=0 || last_fx!=0 || menu!=1) $fatal(1,"fx bypass");
 button(10);if(menu!=2) $fatal(1,"song page");
 rotate(1);if(!song || local_song!=2) $fatal(1,"song choice 2");
 rotate(1);if(local_song!=3) $fatal(1,"song choice 3");
 rotate(1);if(local_song!=1) $fatal(1,"song choice wrap");
 button(10);if(menu!=3) $fatal(1,"tempo page");
 rotate(1);if(tempo!=125) $fatal(1,"tempo");
 button(45);if(tempo!=120) $fatal(1,"tempo reset");
 button(10);if(menu!=4) $fatal(1,"test page");
 button(45);if(tests!=1 || menu!=4) $fatal(1,"test long action");
 button(10);if(menu!=5) $fatal(1,"analysis page");
 rotate(1);if(inspect_band!=1) $fatal(1,"analysis frequency selection");
 button(10);if(menu!=0) $fatal(1,"page wrap");
 $display("PASS EC11_B short/long, bypass, units, FX, score, tempo");$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule

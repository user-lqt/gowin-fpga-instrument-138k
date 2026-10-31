`include "event_defs.vh"
module encoder_b_control #(
 parameter integer FILTER_CYCLES=2500, BUTTON_CYCLES=245760,
 parameter integer LONG_CYCLES=9830400, VOICES=32
)(input wire clk,rst_n,enc_a,enc_b,enc_sw_n,
 output wire input_ready, output reg [2:0] menu,
 output reg [6:0] glide_value,effect_value,
 output reg glide_enabled, output reg [7:0] tempo,
 output reg song_select, output reg lesson_toggle, output reg test_toggle,
 output reg [1:0] local_song,
 output reg [5:0] inspect_band,
 output reg [6:0] test_selection,
 output reg param_valid, output reg [3:0] param_id,
 output reg [15:0] param_value);
 localparam integer LAST_TEST_SELECTION=VOICES+4;
 wire up,down,held,press,release_button;
 reg [31:0] held_cycles;reg long_done;reg [1:0] startup;
 wire long_action=held && !long_done && held_cycles>=LONG_CYCLES-1;
 wire short_action=release_button && !long_done;
 encoder #(.FILTER_CYCLES(FILTER_CYCLES)) rotation(
 .clk(clk),.rst_n(rst_n),.enc_a(enc_a),.enc_b(enc_b),
 .step_up(up),.step_down(down),.input_ready(input_ready));
 key_debounce #(.DEBOUNCE_CYCLES(BUTTON_CYCLES)) button(
 .clk(clk),.rst_n(rst_n),.key_raw(~enc_sw_n),.key_stable(held),
 .key_press(press),.key_release(release_button));
 function [15:0] mix_payload;
 input [6:0] value;reg [15:0] base;
 begin base=({9'd0,value}<<9)+({9'd0,value}<<2);
 mix_payload=base+(value<=21 ? 0 : value<=63 ? 1 : value<=105 ? 2 : 3);end
 endfunction
 // 1..25 ->20..500ms at48kHz; zero bypasses.
 function [15:0] glide_payload;
 input [6:0] value;begin glide_payload=value*16'd960;end endfunction
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
 menu<=0;glide_value<=15;effect_value<=0;glide_enabled<=0;
 tempo<=120;song_select<=0;lesson_toggle<=0;test_toggle<=0;local_song<=1;inspect_band<=0;test_selection<=0;
 held_cycles<=0;long_done<=0;startup<=0;
 param_valid<=0;param_id<=`PARAM_GLIDE;param_value<=0;
 end else begin
 param_valid<=0;lesson_toggle<=0;test_toggle<=0;
 if(press) begin held_cycles<=0;long_done<=0;end
 else if(held && !long_done) held_cycles<=held_cycles+1'b1;
 if(long_action) long_done<=1;
 if(startup<2) begin
 param_valid<=1;param_value<=0;param_id<=startup==0 ? `PARAM_GLIDE : `PARAM_EFFECT_MIX;startup<=startup+1'b1;
 end else if(long_action) begin
 case(menu)
 0:begin glide_enabled<=!glide_enabled && glide_value!=0;
 param_valid<=1;param_id<=`PARAM_GLIDE;param_value<=glide_enabled ? 0 : glide_payload(glide_value);end
 1:begin effect_value<=0;param_valid<=1;param_id<=`PARAM_EFFECT_MIX;param_value<=0;end
 2:lesson_toggle<=1;
 3:tempo<=120;
 4:test_toggle<=1;
 endcase
 end else if(short_action) menu<=menu==3'd5 ? 3'd0 : menu+3'd1;
 else if(up ^ down) begin
 case(menu)
 0:begin
 if(up && glide_value<25) begin glide_value<=glide_value+1'b1;
 param_valid<=1;param_id<=`PARAM_GLIDE;param_value<=glide_enabled ? glide_payload(glide_value+1'b1) : 0;end
 else if(down && glide_value!=0) begin glide_value<=glide_value-1'b1;
 if(glide_value==1) glide_enabled<=0;
 param_valid<=1;param_id<=`PARAM_GLIDE;param_value<=glide_enabled ? glide_payload(glide_value-1'b1) : 0;end
 end
 1:begin
 if(up && effect_value<127) begin effect_value<=effect_value>=123 ? 7'd127 : effect_value+7'd4;
 param_valid<=1;param_id<=`PARAM_EFFECT_MIX;param_value<=mix_payload(effect_value>=123 ? 7'd127 : effect_value+7'd4);end
 else if(down && effect_value!=0) begin effect_value<=effect_value<4 ? 7'd0 : effect_value-7'd4;
 param_valid<=1;param_id<=`PARAM_EFFECT_MIX;param_value<=mix_payload(effect_value<4 ? 7'd0 : effect_value-7'd4);end
 end
 2:begin song_select<=up;local_song<=up ? (local_song==2'd3 ? 2'd1 : local_song+2'd1) : (local_song==2'd1 ? 2'd3 : local_song-2'd1);end
 3:if(up && tempo<200) tempo<=tempo+8'd5;else if(down && tempo>40) tempo<=tempo-8'd5;
 4:test_selection<=up ? (test_selection==VOICES+4 ? 7'd0 : test_selection+1'b1) :
                        (test_selection==0 ? LAST_TEST_SELECTION[6:0] : test_selection-1'b1);
 5:inspect_band<=up ? inspect_band+1'b1 : inspect_band-1'b1;
 endcase
 end
 end end
endmodule

`include "event_defs.vh"
//128ms @48kHz, half-scale wet maximum. Direct sound retained, no feedback.
module audio_delay_fx(input wire clk,rst_n,valid,param_valid,
 input wire [3:0] param_id,input wire [15:0] param_value,
 input wire signed [23:0] audio_in,output reg signed [23:0] audio_out,
 output reg saturated);
 reg signed [23:0] memory[0:6143];reg [12:0] address,filled;
 reg signed [23:0] delayed,source;reg [15:0] mix;reg stage;
 wire signed [24:0] wet=filled==6144 ? $signed(delayed) : 25'sd0;
 wire signed [41:0] product=wet*$signed({1'b0,mix});
 wire signed [42:0] result=$signed(source)+(product >>> 17);
 always @(posedge clk) begin delayed<=memory[address];
 if(rst_n && valid) memory[address]<=audio_in;end
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin address<=0;filled<=0;mix<=0;stage<=0;source<=0;audio_out<=0;saturated<=0;end
 else begin
 if(param_valid && param_id==`PARAM_EFFECT_MIX) mix<=param_value;
 if(valid) begin source<=audio_in;stage<=1;end
 else if(stage) begin
 saturated<=result>8388607 || result< -8388608;
 audio_out<=result>8388607 ? 24'sh7fffff : result< -8388608 ? 24'sh800000 : result[23:0];
  address<=address==13'd6143 ? 13'd0 : address+13'd1;
 if(filled<6144) filled<=filled+1'b1;stage<=0;
 end end end
endmodule

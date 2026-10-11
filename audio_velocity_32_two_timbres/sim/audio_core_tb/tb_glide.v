`timescale 1ns/1ps
`include "event_defs.vh"
module tb_glide;
 reg clk=0,rst=0,tick=0,pv=0;always #5 clk=~clk;
 reg [1:0] on=0;reg [13:0] notes={7'd72,7'd60};
 wire [31:0] fc60,fc72;wire [47:0] p60,p72;
 note_to_fc f0(7'd60,fc60);note_to_fc f1(7'd72,fc72);
 note_to_period p0(7'd60,p60);note_to_period p1(7'd72,p72);
 reg [15:0] glide=480;wire [63:0] fcs;wire [95:0] periods;
 pitch_expression_bank #(.VOICES(2)) dut(.clk(clk),.rst_n(rst),.sample_tick(tick),
 .param_valid(pv),.param_id(`PARAM_GLIDE),.param_value(glide),.note_on(on),.notes(notes),
 .base_fcs({fc72,fc60}),.base_periods({p72,p60}),.fcs(fcs),.periods(periods),.busy());
 task sample;begin tick=1;@(negedge clk);tick=0;repeat(255) @(negedge clk);end endtask
 reg [31:0] previous;integer n;
 initial begin
 repeat(4) @(negedge clk);rst=1;pv=1;@(negedge clk);pv=0;
 on=1;@(negedge clk);on=0;sample;
 on=2;#1;if(fcs[63:32]!=fc60) $fatal(1,"glide starting pitch");
 @(negedge clk);on=0;sample;previous=fcs[63:32];
 for(n=0;n<500;n=n+1) begin sample;
 if(fcs[63:32]<previous || fcs[63:32]>fc72) $fatal(1,"glide monotonicity");previous=fcs[63:32];end
 if(fcs[63:32]!=fc72) $fatal(1,"target not reached");
 glide=0;pv=1;@(negedge clk);pv=0;sample;
 on=1;#1;if(fcs[31:0]!=fc60) $fatal(1,"bypass starting pitch");
 @(negedge clk);on=0;sample;
 if(fcs[31:0]!=fc60) $fatal(1,"bypass drift");
 $display("PASS real glide interpolates from previous pitch, settles, zero bypass");$finish;
 end
endmodule

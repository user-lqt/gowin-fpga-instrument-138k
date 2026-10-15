`timescale 1ns/1ps
module tb_audio_visualizer;
 reg ac=0,pc=0,rst=0,valid=0,fs=0;
 reg signed [15:0] sample=0;
 always #5 ac=~ac;
 always #7 pc=~pc;
 wire [127:0] levels;
 reg [13:0] addr=0;
 wire hit,ready;
 audio_visualizer dut(.audio_clk(ac),.audio_rst_n(rst),.valid(valid),.sample(sample),
 .spectrum(levels),.pixel_clk(pc),.pixel_rst_n(rst),.frame_start(fs),.xy_address(addr),.xy_hit(hit),.xy_ready(ready));
 integer n,i,hits,peak,band,level;
 real angle;
 task push;input integer value;begin
 @(negedge ac);sample=value;valid=1;
 @(negedge ac);valid=0;
 repeat(254) @(negedge ac);
 end endtask
 initial begin
 repeat(5) @(negedge ac);rst=1;
 // 750Hz exactly matches bin 8, index5; 48kHz sample spacing.
 for(n=0;n<1536;n=n+1) begin
 angle=6.283185307179586*n/64.0;push($rtoi(2000*$sin(angle)));
 end
 peak=0;band=-1;
 for(i=0;i<16;i=i+1) begin
 level=levels[i*8+:8];if(level>peak) begin peak=level;band=i;end
 end
 if(band!=5 || peak==0) $fatal(1,"750Hz peak: band=%0d level=%0d",band,peak);
 if(!dut.waiting) $fatal(1,"XY capture not ready");
 @(negedge pc);fs=1;repeat(3) @(negedge pc);fs=0;
 if(!ready) $fatal(1,"XY bank swap failed");
 hits=0;
 for(i=0;i<16384;i=i+1) begin
 addr=i;repeat(2) @(negedge pc);
 if(hit===1'b1) hits=hits+1;
 if(hit===1'bx) $fatal(1,"uncleared XY pixel");
 end
 if(hits<20 || hits>200) $fatal(1,"XY points=%0d",hits);
 // A whole silent window must clear every spectrum band.
 for(n=0;n<512;n=n+1) push(0);
 if(levels!==0) $fatal(1,"silence retained spectral energy %h",levels);
 rst=0;repeat(3) @(negedge ac);rst=1;
 if(levels!==0 || ready!==0) $fatal(1,"reset failed");
 $display("PASS: 750Hz peak at correct DFT bin, real XY points, initialized bitmap, silence, reset");$finish;
 end
 initial begin #20000000;$fatal(1,"timeout");end
endmodule

`timescale 1ns/1ps
`include "event_defs.vh"
module tb_fx_wave;
 reg clk=0,pclk=0,rst=0,valid=0,pv=0,frame=0;always #5 clk=~clk;always #7 pclk=~pclk;
 reg signed [23:0] source=0;reg [15:0] mix=65535;
 wire signed [23:0] out;
 audio_delay_fx fx(.clk(clk),.rst_n(rst),.valid(valid),.param_valid(pv),
 .param_id(`PARAM_EFFECT_MIX),.param_value(mix),.audio_in(source),.audio_out(out));
 reg wvalid=0;reg signed [15:0] ws=0;reg [8:0] address=0;
 wire signed [15:0] lo,hi;wire ready;
 waveform_buffer wb(.audio_clk(clk),.audio_rst_n(rst),.valid(wvalid),.sample(ws),
 .pixel_clk(pclk),.pixel_rst_n(rst),.frame_start(frame),.read_address(address),
 .minimum(lo),.maximum(hi),.ready(ready));
 integer n;
 task push;input integer value;begin source=value;valid=1;@(negedge clk);valid=0;repeat(3) @(negedge clk);end endtask
 initial begin
 repeat(4) @(negedge clk);rst=1;pv=1;@(negedge clk);pv=0;
 push(1000000);if(out!=1000000) $fatal(1,"direct sound");
 for(n=1;n<6144;n=n+1) begin push(0);if(out!=0) $fatal(1,"early echo");end
 push(0);if(out<499980 || out>500000) $fatal(1,"128ms echo %d",out);
 mix=0;pv=1;@(negedge clk);pv=0;push(-123456);if(out!=-123456) $fatal(1,"FX zero bypass");
 for(n=0;n<1024;n=n+1) begin ws=n[0] ? 16'sd3000 : -16'sd2000;wvalid=1;@(negedge clk);end
 wvalid=0;repeat(6) @(negedge pclk);frame=1;@(negedge pclk);frame=0;
 repeat(5) @(negedge pclk);if(!ready || lo!=-2000 || hi!=3000) $fatal(1,"wave minmax");
 // Build the next bank; the displayed bank remains frozen until frame start.
 for(n=0;n<1024;n=n+1) begin ws=n[0] ? 16'sd1000 : -16'sd1000;wvalid=1;@(negedge clk);end
 repeat(2) @(negedge clk);wvalid=0;repeat(6) @(negedge pclk);
 if(lo!=-2000 || hi!=3000) $fatal(1,"display bank mutated");
 // Allow the asynchronous request/acknowledge handshake to settle before
 // presenting the frame boundary. This is the same cadence as the LCD frame.
 repeat(8) @(negedge pclk);
 frame=1;@(negedge pclk);frame=0;repeat(5) @(negedge pclk);
 if(lo!=-1000 || hi!=1000) $fatal(1,"wave swap lo=%d hi=%d ready=%b",lo,hi,ready);
 $display("PASS FX direct/128ms echo/bypass and asynchronous frozen waveform minmax banks");$finish;
 end
endmodule

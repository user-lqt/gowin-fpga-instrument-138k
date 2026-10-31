`timescale 1ns/1ps
module tb_wave_response;
 reg clk=0,pclk=0,rst=0,valid=0,pf=0;
 always #5 clk=~clk;
 always #7 pclk=~pclk;
 reg signed [15:0] sample=0;
 reg [8:0] address=0;
 wire ready;
 wire [3:0] shift;
 wire signed [15:0] lo,hi;
 waveform_buffer dut(.audio_clk(clk),.audio_rst_n(rst),.valid(valid),.sample(sample),
 .pixel_clk(pclk),.pixel_rst_n(rst),.frame_start(pf),.read_address(address),
 .minimum(lo),.maximum(hi),.ready(ready),.scale_shift(shift));
 task send(input integer value);
 begin @(negedge clk);sample=value;valid=1;@(negedge clk);valid=0;end endtask
 task capture(input integer amplitude);
 integer i;
 reg [3:0] old;
 begin
 old=shift;
 send(-1);
 // Force a well-defined rising trigger, then cover all 1024 samples.
 send(amplitude);
 for(i=1;i<1024;i=i+1) send(i%2==0 ? amplitude : -amplitude);
 if(!dut.waiting || shift!=old) $fatal(1,"scale changed before bank handoff");
 repeat(6) @(negedge pclk);pf=1;@(negedge pclk);pf=0;
 repeat(8) @(negedge clk);
 if(!ready || dut.waiting) $fatal(1,"handoff");
 if((amplitude>>shift)>32) $fatal(1,"positive display clip");
 if(((-amplitude)>>>shift)<-32) $fatal(1,"negative display clip");
 for(i=0;i<512;i=i+1) begin
 @(negedge pclk);address=i;
 repeat(2) @(negedge pclk);
 if(lo!==-amplitude || hi!==amplitude)
 $fatal(1,"min/max loss bin=%0d lo=%0d hi=%0d amp=%0d",i,lo,hi,amplitude);
 end
 end endtask
 integer i;
 initial begin
 repeat(4) @(negedge clk);rst=1;
 capture(500);
 if(shift!=5 || (500>>shift)<14) $fatal(1,"first small capture invisible");
 capture(32767);if(shift!=10) $fatal(1,"fullscale attack");
 for(i=0;i<3;i=i+1) begin capture(500);if(shift!=10) $fatal(1,"early recovery");end
 capture(500);if(shift!=5) $fatal(1,"four-capture recovery");
 capture(100);capture(400);capture(100);capture(100);
 if(shift!=4) $fatal(1,"recovery must retain largest required range");
 for(i=0;i<3072;i=i+1) send(-32768);
 if(!dut.waiting || dut.published_shift!=10) $fatal(1,"negative rail magnitude");
 repeat(6) @(negedge pclk);pf=1;@(negedge pclk);pf=0;
 repeat(8) @(negedge clk);
 repeat(2) @(negedge pclk);
 if(lo!==-32768 || hi!==-32768 || shift!=10) $fatal(1,"negative rail min/max");
 for(i=0;i<4;i=i+1) capture(0);
 if(shift!=2) $fatal(1,"silence floor");
 capture(16);if(shift!=2) $fatal(1,"LSB noise amplification");
 capture(2000);if(shift!=7) $fatal(1,"transient attack");
 $display("PASS waveform first-capture visibility, four-window recovery, stable scale, min/max, noise floor and fullscale");
 $finish;
 end
 initial begin #10000000;$fatal(1,"timeout");end
endmodule

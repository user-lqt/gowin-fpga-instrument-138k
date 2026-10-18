`timescale 1ns/1ps
module tb_test_dashboard;
 reg clk=0,rst=0;
 always #5 clk=~clk;
 reg [209:0] status=0;
 instrument_dashboard dut(.pixel_clk(clk),.rst_n(rst),.status(status),
 .spectrum(128'd0),.features(49'd0),.xy_hit(1'b0),.xy_ready(1'b0),
 .wave_min(16'sd0),.wave_max(16'sd0),.wave_ready(1'b0));
 reg [209:0] held;
 integer n,i,blue;
 initial begin
 repeat(3) @(negedge clk);rst=1;
 held=0;held[149]=1; // menu=4, TEST page
 force dut.frame=held;
 #1;
 if(!dut.test_page || dut.analysis_page) $fatal(1,"test page decode");
 if(dut.text_line(2)!==" MIX WAVE / AUTO SCALE             32 VOICE TEST ")
   $fatal(1,"dedicated test title");
 for(n=0;n<=32;n=n+1) begin
 held[78:73]=n;held[148]=1;
 repeat(310) @(negedge clk);
 if(dut.b_voices!==dut.decimal3(n)) $fatal(1,"voice count BCD");
 if(dut.character(4,42,dut.text_line(4))!==dut.digit(dut.decimal3(n),1) ||
    dut.character(4,43,dut.text_line(4))!==dut.digit(dut.decimal3(n),0) ||
    dut.character(4,41,dut.text_line(4))!==8'h20)
    $fatal(1,"test voice glyphs");
 blue=0;
 force dut.v=440;
 for(i=0;i<32;i=i+1) begin
 force dut.h=144+i*16;#1;
 if(dut.r==6 && dut.g==29 && dut.b==60) blue=blue+1;
 end
 if(blue!=n) $fatal(1,"32-slot count %0d expected %0d",blue,n);
 release dut.h;release dut.v;
 end
 held=0;#1;
 if(dut.text_line(23)!==" 94HZ   750HZ    18K                             ")
   $fatal(1,"home TEST indicator remains");
 force dut.h=10;force dut.v=418;#1;
 if({dut.r,dut.g,dut.b}!=={6'd63,6'd63,6'd63}) $fatal(1,"white canvas");
 release dut.h;release dut.v;release dut.frame;
 $display("PASS dedicated TEST page, 0..32 count/glyphs/slots, home cleanup, white canvas");
 $finish;
 end
endmodule

`timescale 1ns/1ps
module tb_guitar_equivalence;
 reg clk=0,rst_n=0,tick=0,on=0;
 reg [31:0] fc=0;
 reg [47:0] period=0;
 reg [7:0] velocity=16;
 wire signed [15:0] actual,reference;
 always #5 clk=~clk;
 plucked_string dut(clk,rst_n,tick,on,1'b1,fc,period,velocity,actual);
 plucked_string_reference ref_dut(clk,rst_n,tick,on,1'b1,fc,period,velocity,reference);
 integer n,v,f,c;
 reg [34:0] p;
 initial begin
   for(n=0;n<131072;n=n+1) begin
     p=n*18'd174763;
     if((p>>19)!=n/3) $fatal(1,"division 3 mismatch %d",n);
   end
   for(n=0;n<4096;n=n+1) begin
     p=n*12'd2731;
     if((p>>13)!=n/3) $fatal(1,"pick loss mismatch %d",n);
     p=n*13'd3277;
     if((p>>14)!=n/5) $fatal(1,"warm mismatch %d",n);
   end
   for(v=0;v<3;v=v+1) begin
     rst_n=0; repeat(4) @(negedge clk); rst_n=1;
     velocity=v==0 ? 16 : v==1 ? 80 : 127;
     fc=32'd39370534; period=48'd7148870166;
     on=1; @(negedge clk);on=0;
     for(f=0;f<4096;f=f+1) begin
       for(c=0;c<256;c=c+1) begin
         tick=c==0; @(negedge clk);
         if(actual!==reference) $fatal(1,"PCM mismatch v=%d frame=%d",velocity,f);
       end
     end
   end
   $display("PASS exact divisions and 12288 guitar frames match reference");
   $finish;
 end
endmodule

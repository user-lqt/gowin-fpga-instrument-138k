`timescale 1ns/1ps
module tb_dashboard_preview;
 parameter ANALYSIS=0;
 reg clk=0,rst=0;always #15 clk=~clk;
 reg [168:0] status=0;
 reg [127:0] spectrum=0;
 wire [8:0] wa;wire [13:0] xy;
 wire ready,sc,hs,vs,de;wire [5:0] r,g,b;
 reg signed [15:0] lo,hi;
 reg hit;
 integer i,out,pixels=0;real a;
 instrument_dashboard dut(.pixel_clk(clk),.rst_n(rst),.status(status),.spectrum(spectrum),
 .features({4'd5,4'd5,10'd12,10'd2,10'd24,2'd2,1'b1,1'b0,1'b0,1'b1,1'b0,1'b1,3'd2}),
 .xy_address(xy),.xy_hit(hit),.xy_ready(1'b1),.wave_address(wa),.wave_min(lo),.wave_max(hi),.wave_ready(1'b1),
 .frame_start(ready),.sc_clk(sc),.sc_hs(hs),.sc_vs(vs),.sc_de(de),.r_out(r),.g_out(g),.b_out(b));
 always @(posedge clk) begin
 a=6.28318530718*wa/64.0;lo=$rtoi(2200*$sin(a))-100;hi=lo+200;
 hit=((xy[6:0]-64)*(xy[6:0]-64)+(xy[13:7]-64)*(xy[13:7]-64)>1800 &&
      (xy[6:0]-64)*(xy[6:0]-64)+(xy[13:7]-64)*(xy[13:7]-64)<1950);
 end
 initial begin
 status[31:16]=32768;status[78:73]=4;status[94:87]=127;status[101:95]=69;
 status[106:102]=9;status[71:70]=2;status[69:63]=15;status[72]=1;
 status[168:167]=2;status[164:155]=60;status[123:119]=12;status[116]=1;
 status[147:124]=24'd1<<9;status[55:32]=24'd1<<9;
 if(ANALYSIS) begin status[149]=1;status[71:70]=1;end
 for(i=0;i<16;i=i+1) spectrum[i*8+:8]=(i==5 ? 108 : 16+i*3);
 #100;rst=1;@(posedge ready);@(negedge ready);
 out=$fopen("dashboard_preview.ppm","w");$fwrite(out,"P3\n800 480\n255\n");
 while(pixels<800*480) begin
 @(negedge clk);#1;
 if(de) begin $fwrite(out,"%0d %0d %0d\n",r*4,g*4,b*4);pixels=pixels+1;end
 end
 $fclose(out);$display("PASS: 800x480 rendered frame");$finish;
 end
 initial begin #40000000;$fatal(1,"timeout");end
endmodule

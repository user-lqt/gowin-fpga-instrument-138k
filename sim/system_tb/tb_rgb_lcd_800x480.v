`timescale 1ns/1ps
module tb_rgb_lcd_800x480;
    reg clk=0, rst_n=0;
    always #15 clk=~clk;
    reg [23:0] keys=24'hffffff;
    reg [15:0] adc_digits=16'h0001;
    reg [11:0] vibrato_digits=12'h000;
    wire de,hs,vs,frame;
    wire [5:0] red,green,blue;
    rgb_lcd_800x480 #(.ENABLE_FSR_STATUS(1)) dut (.pixel_clk(clk), .rst_n(rst_n), .key_state(keys),
        .volume_value(16'd64), .instrument_value(16'd0), .frame_start(frame),
        .adc_digits(adc_digits),.vibrato_digits(vibrato_digits),.sensor_ready(1'b1),
        .sc_clk(), .sc_hs(hs), .sc_vs(vs), .sc_de(de), .r_out(red), .g_out(green), .b_out(blue));
    integer i, x, y, active_pixels=0, hs_pixels=0, vs_pixels=0;
    integer key_pixels[0:23];
    integer status_pixels=0;
    initial begin
        for(i=0;i<24;i=i+1) key_pixels[i]=0;
        repeat(4) @(negedge clk); rst_n=1;
        @(posedge clk); #1;
        for(i=0;i<1056*525;i=i+1) begin
            @(negedge clk); #1;
            x=dut.h_count; y=dut.v_count;
            if(de) active_pixels=active_pixels+1;
            if(!hs) hs_pixels=hs_pixels+1;
            if(!vs) vs_pixels=vs_pixels+1;
            if(y==200 && red==8 && green==50 && blue==44)
                key_pixels[(x-4)/33]=key_pixels[(x-4)/33]+1;
            if(y==100) begin keys=0;adc_digits=16'h0899;vibrato_digits=12'h100;end
            if(y>=102 && y<116) begin
                if(dut.frame_adc_digits!==16'h0001 || dut.frame_vibrato_digits!==12'h000)
                    $fatal(1,"FSR display changed in the middle of a frame");
                if(red==63 && green==63 && blue==63) status_pixels=status_pixels+1;
            end
        end
        if(active_pixels!=800*480 || hs_pixels!=128*525 || vs_pixels!=2*1056)
            $fatal(1,"LCD active/sync timing mismatch %0d %0d %0d",active_pixels,hs_pixels,vs_pixels);
        for(i=0;i<24;i=i+1)
            if(key_pixels[i]!=30) $fatal(1,"key %0d clipped or changed midframe: %0d",i,key_pixels[i]);
        if(status_pixels<100) $fatal(1,"FSR decimal status text not rendered");
        wait(frame);@(posedge clk);#1;
        if(dut.frame_adc_digits!==16'h0899 || dut.frame_vibrato_digits!==12'h100)
            $fatal(1,"FSR display did not refresh at next frame");
        $display("PASS RGB full raster timing, 24 equal keys, visible ADC/VIB decimal text and atomic frame snapshots");
        $finish;
    end
    initial begin #30000000; $fatal(1,"LCD timeout"); end
endmodule

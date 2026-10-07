`timescale 1ns/1ps
module tb_audio_frame_buffer;
    reg clk=0,rst_n=0,valid=0,start=0;
    reg signed [23:0] left=0,right=0;
    wire signed [15:0] frame_left,frame_right;
    audio_frame_buffer dut(.clk(clk),.rst_n(rst_n),.pcm_valid(valid),
        .frame_start(start),.pcm_left(left),.pcm_right(right),
        .frame_left(frame_left),.frame_right(frame_right));
    always #5 clk=~clk;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        left=24'h123400;right=-24'sh123400;valid=1;
        @(negedge clk);valid=0;
        if(frame_left!=0 || frame_right!=0) $fatal(1,"PCM committed mid-frame");
        start=1;@(negedge clk);start=0;
        if(frame_left!=16'h1234 || frame_right!=-16'sh1234) $fatal(1,"frame commit/sign");
        left=24'h234500;right=24'h345600;valid=1;
        @(negedge clk);valid=0;
        repeat(20) @(negedge clk);
        if(frame_left!=16'h1234 || frame_right!=-16'sh1234) $fatal(1,"stereo frame torn");
        start=1;@(negedge clk);start=0;
        if(frame_left!=16'h2345 || frame_right!=16'h3456) $fatal(1,"pending frame lost");
        // A sample completing on the frame edge must also commit atomically.
        left=24'h7fff00;right=24'h800000;valid=1;start=1;
        @(negedge clk);valid=0;start=0;
        if(frame_left!=16'h7fff || frame_right!=16'h8000) $fatal(1,"coincident frame/PCM");
        rst_n=0;@(negedge clk);
        if(frame_left!=0 || frame_right!=0) $fatal(1,"frame reset");
        $display("PASS PCM frame buffer stereo atomicity, signed conversion, coincident valid and reset");
        $finish;
    end
endmodule

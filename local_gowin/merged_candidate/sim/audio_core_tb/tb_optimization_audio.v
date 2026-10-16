`timescale 1ns/1ps
`include "event_defs.vh"
module tb_optimization_audio;
    reg clk=0,rst_n=0,tick=0,ev=0,pv=0;
    always #5 clk=~clk;
    reg [1:0] kind=0;
    reg [6:0] note=0;
    reg [7:0] velocity=127;
    reg [3:0] pid=0;
    reg [15:0] value=0;
    wire valid,ready,overload,eo,po;
    wire signed [23:0] left,right;
    wire [5:0] voices;
    audio_core #(.VOICE_COUNT(32),.ENABLE_EXPRESSION(1),.ENABLE_GUITAR(1),
        .RAM_BODY(1),.SHARE_VOICE_ARITHMETIC(1),.RELEASE_SAMPLES(64),
        .BELL_RING_SAMPLES(512)) dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .event_valid(ev),.event_type(kind),.note_id(note),.velocity(velocity),
        .param_valid(pv),.param_id(pid),.param_value(value),
        .audio_core_valid(valid),.audio_left(left),.audio_right(right),
        .active_voice_count(voices),.engine_ready(ready),.overload_flag(overload),
        .event_overflow(eo),.param_overflow(po));
    integer n,t,out,count=0,nonzero=0;
    always @(negedge clk) if(rst_n && valid) begin
        if((^left)===1'bx || left!==right || eo || po)
            $fatal(1,"invalid optimization PCM capture");
        $fwrite(out,"%0d,%0d,%0d,%0d,%0d,%0d\n",t,count,left,right,voices,overload);
        count=count+1;
        if(left!=0) nonzero=nonzero+1;
    end
    initial begin
        out=$fopen("sim/merged_checks/optimization_audio.csv","w");
        for(t=0;t<3;t=t+1) begin
            rst_n=0;tick=0;ev=0;pv=0;
            repeat(5) @(negedge clk);rst_n=1;
            wait(ready);
            for(n=0;n<768;n=n+1) begin
                @(negedge clk);tick=1;ev=0;pv=0;
                if(n==0) begin pv=1;pid=`PARAM_VOLUME;value=512;end
                if(n==1) begin pv=1;pid=`PARAM_INSTRUMENT;value=t;end
                if(n>=8 && n<40) begin
                    ev=1;kind=`EVENT_NOTE_ON;note=48+n-8;
                    velocity=16+((n*17)%112);
                end
                if(n==64) begin pv=1;pid=`PARAM_PITCH_BEND;value=4096;end
                if(n==96) begin pv=1;pid=`PARAM_MODULATION;value=32768;end
                if(n>=128 && n<160) begin ev=1;kind=`EVENT_NOTE_OFF;note=48+n-128;end
                if(n==256) begin pv=1;pid=`PARAM_GLIDE;value=32;end
                if(n==280) begin pv=1;pid=`PARAM_PITCH_BEND;value=16'he000;end
                if(n==300) begin pv=1;pid=`PARAM_MODULATION;value=0;end
                if(n>=320 && n<400 && n%8==0) begin
                    ev=1;kind=`EVENT_NOTE_ON;note=60+((n-320)/8)%5;velocity=110;
                end
                if(n>=324 && n<404 && n%8==4) begin
                    ev=1;kind=`EVENT_NOTE_OFF;note=60+((n-324)/8)%5;
                end
                @(negedge clk);tick=0;ev=0;pv=0;
                repeat(254) @(negedge clk);
            end
            $display("Captured optimization PCM timbre %0d",t);
            $fflush(out);
        end
        $fclose(out);
        if(count!=2304 || nonzero==0) $fatal(1,"incomplete optimization trace");
        $display("PASS 2304 samples, three timbres, 32 notes, velocities, bend, vibrato, glide and release");
        $finish;
    end
endmodule

`timescale 1ns/1ps
`include "event_defs.vh"
module tb_merged_audio;
    reg clk=0,rst_n=0;
    reg [7:0] divider=0;
    wire tick=divider==255;
    always #5 clk=~clk;
    always @(posedge clk) if(!rst_n) divider<=0;else divider<=divider+8'd1;
    reg ev=0,pv=0;
    reg [1:0] kind=0;
    reg [6:0] note=0;
    reg [7:0] velocity=127;
    reg [3:0] pid=0;
    reg [15:0] value=0;
    wire valid,ready,overload,eo,po;
    wire signed [23:0] left,right;
    wire [5:0] voices;
    audio_core #(.VOICE_COUNT(32),.ENABLE_EXPRESSION(1),.ENABLE_GUITAR(1),
        .RAM_BODY(1),.SHARE_VOICE_ARITHMETIC(1),
        .ATTACK_SAMPLES(8),.DECAY_SAMPLES(32),.RELEASE_SAMPLES(64),
        .BELL_RING_SAMPLES(128)) dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .event_valid(ev),.event_type(kind),.note_id(note),.velocity(velocity),
        .param_valid(pv),.param_id(pid),.param_value(value),
        .audio_core_valid(valid),.audio_left(left),.audio_right(right),
        .active_voice_count(voices),.engine_ready(ready),.overload_flag(overload),
        .event_overflow(eo),.param_overflow(po));
    integer cycles=0,previous_valid=0,received=0,nonzero=0,t,k;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles%1000==0) begin
            $display("audio progress: timbre=%0d cycle=%0d samples=%0d voices=%0d",t,cycles,received,voices);
            $fflush();
        end
        if(!rst_n) begin previous_valid=0;received=0;nonzero=0;end
        else begin
            if(eo || po) $fatal(1,"audio event/parameter queue overflow");
            if(overload) $fatal(1,"audio clipping at test gain");
            if(valid) begin
                if((^left)===1'bx || left!==right) $fatal(1,"invalid PCM");
                if(previous_valid!=0 && cycles-previous_valid!=256) $fatal(1,"PCM cadence");
                previous_valid=cycles;received=received+1;
                if(left!=0) nonzero=nonzero+1;
            end
        end
    end
    task parameter_event;
        input [3:0] id;
        input [15:0] payload;
        begin
            @(negedge clk);pv=1;pid=id;value=payload;
            @(negedge clk);pv=0;
            repeat(512) @(negedge clk);
        end
    endtask
    task key_event;
        input [1:0] event_kind;
        input [6:0] n;
        begin
            @(negedge clk);ev=1;kind=event_kind;note=n;
            @(negedge clk);ev=0;
            repeat(300) @(negedge clk);
        end
    endtask
    initial begin
        $dumpfile("audio_smoke_progress.vcd");
        $dumpvars(0,clk,rst_n,valid,voices);
        for(t=0;t<3;t=t+1) begin
            rst_n=0;repeat(5) @(negedge clk);rst_n=1;
            wait(ready);repeat(512) @(negedge clk);
            // Full-velocity 32-note chord: leave headroom for sum saturation.
            parameter_event(`PARAM_VOLUME,16'd1024);
            parameter_event(`PARAM_INSTRUMENT,t);
            for(k=0;k<32;k=k+1) key_event(`EVENT_NOTE_ON,48+k);
            repeat(3000) @(negedge clk);
            if(voices!=32) $fatal(1,"timbre %d voices %d",t,voices);
            parameter_event(`PARAM_PITCH_BEND,16'h1000);
            parameter_event(`PARAM_MODULATION,16'h8000);
            repeat(4096) @(negedge clk);
            parameter_event(`PARAM_PITCH_BEND,0);
            parameter_event(`PARAM_MODULATION,0);
            if(nonzero==0 || received<32) $fatal(1,"silent timbre %d",t);
            for(k=0;k<32;k=k+1) key_event(`EVENT_NOTE_OFF,48+k);
            repeat(256*160) @(negedge clk);
            if(voices!=0) $fatal(1,"release timbre %d voices %d",t,voices);
            $display("PASS timbre %d: 32 voices, nonzero PCM, 256-cycle cadence, expression, release",t);
        end
        $display("PASS merged audio shared arithmetic smoke test");
        $finish;
    end
    initial begin #20000000;$fatal(1,"timeout");end
endmodule

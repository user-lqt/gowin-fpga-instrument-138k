`timescale 1ns/1ps
`include "event_defs.vh"
module tb_core_hardware #(
    parameter integer ENABLE_EXPRESSION=0,
    parameter integer TEST_VIBRATO=0,
    parameter integer TRACE_EXPRESSION=0,
    parameter integer ENABLE_GUITAR=1
);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,tick=0,event_valid=0,param_valid=0;
    reg [1:0] event_type=1;
    reg [6:0] note_id=0;
    reg [7:0] velocity=100;
    reg [3:0] param_id=1;
    reg [15:0] param_value=0;
    wire valid,ready,overload,event_overflow,param_overflow;
    wire signed [23:0] left,right;
    wire [5:0] active;
    reg signed [23:0] held;
    integer divider=0,cycle=0,last_tick=0,last_valid=0;
    integer t,n,i,frames=0,sounded=0;
    audio_core #(.RELEASE_SAMPLES(64),.ENABLE_EXPRESSION(ENABLE_EXPRESSION),
        .ENABLE_GUITAR(ENABLE_GUITAR)) dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .event_valid(event_valid),.event_type(event_type),.note_id(note_id),.velocity(velocity),
        .param_valid(param_valid),.param_id(param_id),.param_value(param_value),
        .audio_core_valid(valid),.audio_left(left),.audio_right(right),
        .active_voice_count(active),.engine_ready(ready),.overload_flag(overload),
        .event_overflow(event_overflow),.param_overflow(param_overflow)
    );
    always @(posedge clk) begin
        if(!rst_n) begin divider<=0;tick<=0;end
        else begin
            divider<=divider==255 ? 0 : divider+1;
            tick<=divider==255;
        end
        cycle=cycle+1;
        if(tick)last_tick=cycle;
        if(TRACE_EXPRESSION==2 && cycle==48282) $stop;
        if(TRACE_EXPRESSION==2 && cycle>=48282)
            $display("DEBUG CYCLE %0d",cycle);
        if(TRACE_EXPRESSION==1 && frames>=158 && frames<192) begin
            $display("TRACE frame=%0d cycle=%0d divider=%0d",frames,cycle,divider);
            $fflush();
        end
        #1;
        if(!rst_n)begin last_valid=0;held=0;end
        else if(valid)begin
            if(cycle-last_tick!=109 || (last_valid!=0 && cycle-last_valid!=256))
                $fatal(1,"hardware cadence/latency");
            if((^left)===1'bx || left!==right || overload || event_overflow || param_overflow)
                $fatal(1,"hardware PCM/overflow fault");
            last_valid=cycle;held=left;frames=frames+1;
            if(frames%32==0) begin
                $display("HARDWARE progress frames=%0d t=%0d active=%0d",frames,t,active);
                $fflush();
            end
            if(left!=0)sounded=sounded+1;
        end else if(left!==held)$fatal(1,"hardware output hold");
    end
    generate if(ENABLE_EXPRESSION) begin : expression_deadline
        always @(posedge clk)
            if(rst_n && tick && dut.a2.expression.u_pitch.busy)
                $fatal(1,"expression cadence missed sample deadline");
    end endgenerate
    task wait_samples;
        input integer count;
        integer s;
        for(s=0;s<count;s=s+1)begin @(posedge valid);@(negedge clk);end
    endtask
    task event_note;
        input [1:0] kind;
        input [6:0] note;
        begin
            @(negedge clk);event_valid=1;event_type=kind;note_id=note;
            @(negedge clk);event_valid=0;
        end
    endtask
    initial begin
        for(t=0;t<(ENABLE_GUITAR ? 3 : 2);t=t+1)begin
            @(negedge clk);rst_n=0;event_valid=0;param_valid=0;
            repeat(4)@(negedge clk);rst_n=1;
            $display("HARDWARE start t=%0d expression=%0d",t,ENABLE_EXPRESSION);
            $fflush();
            wait(ready);
            @(negedge clk);param_valid=1;param_value=ENABLE_GUITAR ? t : t*2;
            @(negedge clk);param_valid=0;
            wait_samples(2);sounded=0;
            for(n=0;n<32;n=n+1)event_note(1,48+n);
            wait_samples(96);
            if(active!=32 || sounded<50)$fatal(1,"32 hardware voices not sounding t=%0d",t);
            if(ENABLE_EXPRESSION) begin
                @(negedge clk);param_valid=1;param_id=`PARAM_PITCH_BEND;param_value=16'h1fff;
                @(negedge clk);param_valid=0;
                wait_samples(132);
                if(active!=32)
                    $fatal(1,"32-voice bend settling");
                @(negedge clk);param_valid=1;param_id=`PARAM_PITCH_BEND;param_value=0;
                @(negedge clk);param_valid=0;
                wait_samples(132);
                @(negedge clk);param_valid=1;param_id=`PARAM_GLIDE;param_value=37;
                @(negedge clk);param_valid=0;
                wait_samples(2);
                event_note(1,48);
                wait_samples(2);
                event_note(1,79);
                if(TEST_VIBRATO) begin
                    @(negedge clk);param_valid=1;param_id=`PARAM_MODULATION;param_value=65535;
                    @(negedge clk);param_valid=0;
                    @(negedge clk);param_valid=1;param_id=`PARAM_PITCH_BEND;param_value=16'h1fff;
                    @(negedge clk);param_valid=0;
                    wait_samples(260);
                    if(dut.a2.expression.u_pitch.u_vibrato.depth!==65535 ||
                       dut.a2.expression.u_pitch.bend!==16'sd8191 || active!=32)
                        $fatal(1,"vibrato/bend/glide full-load controls");
                    for(i=0;i<32;i=i+1)
                        if(dut.a2.rendered_fc[i*32+:32] <= dut.a2.voice_fc[i*32+:32] ||
                           dut.a2.rendered_period[i*48+:48] >= dut.a2.voice_period[i*48+:48])
                            $fatal(1,"full-load combined pitch not applied slot=%0d",i);
                    @(negedge clk);param_valid=1;param_id=`PARAM_MODULATION;param_value=0;
                    @(negedge clk);param_valid=0;
                    @(negedge clk);param_valid=1;param_id=`PARAM_PITCH_BEND;param_value=0;
                    @(negedge clk);param_valid=0;
                    wait_samples(260);
                    if(dut.a2.expression.u_pitch.vibrato_pitch!==0)
                        $fatal(1,"vibrato disable did not restore neutral");
                end
                wait_samples(42);
                for(i=0;i<32;i=i+1) begin
                    if(dut.a2.expression.u_pitch.pitch[i]!==dut.a2.expression.u_pitch.goal[i] ||
                       dut.a2.rendered_fc[i*32+:32]!==dut.a2.voice_fc[i*32+:32])
                        $fatal(1,"full-load glide endpoint/held pitch slot=%0d",i);
                end
                if(active!=32) $fatal(1,"full-load glide changed voice allocation");
                @(negedge clk);param_valid=1;param_id=`PARAM_GLIDE;param_value=0;
                @(negedge clk);param_valid=0;
                wait_samples(2);
            end
            for(n=0;n<32;n=n+1)begin
                if(dut.a2.voice_note_id[n*7+:7]!=48+n)$fatal(1,"distinct hardware notes missing");
                event_note(2,48+n);
            end
            wait_samples(128);
            if(active!=0 || left!=0)$fatal(1,"hardware release stuck t=%0d",t);
            $display("PASS hardware t=%0d: 32 voices, distinct notes, silent release, 256-cycle samples",t);
            $fflush();
            param_id=`PARAM_INSTRUMENT;
        end
        $display("HARDWARE CADENCE PASS: %0d valid frames, latency109, period256",frames);
        $finish;
    end
    initial begin #20000000;$fatal(1,"hardware test timeout");end
endmodule

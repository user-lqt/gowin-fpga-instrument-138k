`timescale 1ns/1ps
`include "event_defs.vh"
// Real event FIFO -> allocator -> expression wiring, including release tails
// and the allocator's broadcast-base-pitch optimization.
module tb_legato_core;
    reg clk=0,rst_n=0,ev=0,pv=0;
    always #5 clk=~clk;
    reg [7:0] divider=0;
    wire tick=divider==255;
    always @(posedge clk) if(!rst_n) divider<=0;else divider<=divider+1'b1;
    reg [1:0] kind=0;
    reg [6:0] note=0;
    wire ready,valid,eo,po;
    wire signed [23:0] left,right;
    wire [31:0] fc48,fc60;
    note_to_fc f0(7'd48,fc48),f1(7'd60,fc60);
    audio_core #(.VOICE_COUNT(32),.ENABLE_EXPRESSION(1),.ENABLE_GUITAR(0),
        .RAM_BODY(1),.SHARE_VOICE_ARITHMETIC(1),.ATTACK_SAMPLES(8),
        .DECAY_SAMPLES(16),.RELEASE_SAMPLES(4800)) dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .event_valid(ev),.event_type(kind),.note_id(note),.velocity(8'd100),
        .param_valid(pv),.param_id(`PARAM_GLIDE),.param_value(16'd48),
        .audio_core_valid(valid),.audio_left(left),.audio_right(right),
        .active_voice_count(),.engine_ready(ready),.overload_flag(),
        .event_overflow(eo),.param_overflow(po));
    integer pcm_count=0,cycle=0,last_pcm=0;
    always @(negedge clk) if(rst_n) begin
        cycle=cycle+1;
        if(eo || po) $fatal(1,"core queue overflow");
        if(valid) begin
            if((^left)===1'bx || left!==right) $fatal(1,"unknown/stereo mismatch PCM");
            if(last_pcm!=0 && cycle-last_pcm!=256) $fatal(1,"PCM cadence changed");
            last_pcm=cycle;pcm_count=pcm_count+1;
        end
    end
    integer k,target;
    task key_event;
        input [1:0] event_kind;
        input [6:0] note_id;
        input [31:0] expected_fc;
        input signed [23:0] expected_pitch;
        input [15:0] expected_remaining;
        begin
            @(negedge clk);ev=1;kind=event_kind;note=note_id;
            @(negedge clk);ev=0;
            if(event_kind==`EVENT_NOTE_ON) begin
                wait(|dut.a2.voice_note_on);#1;
                target=-1;
                for(k=0;k<32;k=k+1) if(dut.a2.voice_note_on[k]) target=k;
                if(target<0 || !dut.a2.key_down[target] ||
                   dut.a2.rendered_fc[target*32+:32]!==expected_fc)
                    $fatal(1,"core incorrect immediate NOTE_ON pitch for note %0d",note_id);
                @(negedge clk);@(negedge clk);
                if(dut.a2.expression.u_pitch.pitch[target]!==expected_pitch ||
                   dut.a2.expression.u_pitch.remaining[target]!==expected_remaining)
                    $fatal(1,"core legato state note %0d",note_id);
            end else begin
                wait(|dut.a2.voice_note_off);#1;
                if(|(dut.a2.voice_note_off & dut.a2.key_down))
                    $fatal(1,"NOTE_OFF did not clear key_down");
            end
            repeat(300) @(negedge clk);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst_n=1;wait(ready);
        @(negedge clk);pv=1;@(negedge clk);pv=0;
        repeat(512) @(negedge clk);
        key_event(`EVENT_NOTE_ON,60,fc60,24'sd3932160,0);
        key_event(`EVENT_NOTE_ON,72,fc60,24'sd3932160,48);
        repeat(50*256) @(negedge clk);
        key_event(`EVENT_NOTE_OFF,72,0,0,0);
        // Latest key was released: use still-held C4, not the E5 event base
        // broadcast or the released C5 voice's pitch.
        key_event(`EVENT_NOTE_ON,76,fc60,24'sd3932160,48);
        key_event(`EVENT_NOTE_OFF,60,0,0,0);
        key_event(`EVENT_NOTE_OFF,76,0,0,0);
        if(dut.a2.key_down!==0 || dut.a2.voice_active===0)
            $fatal(1,"test must have release tails but no held keys");
        key_event(`EVENT_NOTE_ON,48,fc48,24'sd3145728,0);
        key_event(`EVENT_NOTE_OFF,48,0,0,0);
        if(dut.a2.key_down!==0 || pcm_count<50) $fatal(1,"core test incomplete");
        $display("PASS 32-voice core legato: FIFO/allocator wiring, latest-held fallback, release-tail exclusion and PCM cadence");
        $finish;
    end
    initial begin #2000000;$fatal(1,"core legato timeout");end
endmodule

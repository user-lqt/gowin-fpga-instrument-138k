`timescale 1ns/1ps
`include "event_defs.vh"
module tb_strike_dynamics;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,tick=0,on_event=0,off_event=0,param_valid=0;
    reg [7:0] velocity=32;
    reg [15:0] timbre=0;
    wire valid,held_valid,ready,overload;
    wire signed [23:0] pcm,held_pcm;
    wire [5:0] active;
    integer divider=0,i,t,s,trace,previous_gain;
    reg [7:0] curve_velocity=0;
    wire [7:0] curve_gain;
    strike_profile curve(.velocity(curve_velocity),.instrument(2'd0),.gain(curve_gain));
    always @(posedge clk) begin
        if(!rst_n) begin divider<=0;tick<=0;end
        // Single-voice diagnostic runs at 96 clocks/sample. The separate
        // 32-voice hardware regression verifies the real 256-clock budget.
        else begin divider<=divider==95 ? 0 : divider+1;tick<=divider==95;end
    end
    audio_core #(.VOICE_COUNT(1)) tapped(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .event_valid(on_event|off_event),
        .event_type(off_event ? `EVENT_NOTE_OFF : `EVENT_NOTE_ON),
        .note_id(7'd69),.velocity(velocity),
        .param_valid(param_valid),.param_id(`PARAM_INSTRUMENT),.param_value(timbre),
        .audio_core_valid(valid),.audio_left(pcm),.active_voice_count(active),
        .engine_ready(ready),.overload_flag(overload));
    audio_core #(.VOICE_COUNT(1)) held(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .event_valid(on_event),.event_type(`EVENT_NOTE_ON),
        .note_id(7'd69),.velocity(velocity),
        .param_valid(param_valid),.param_id(`PARAM_INSTRUMENT),.param_value(timbre),
        .audio_core_valid(held_valid),.audio_left(held_pcm));
    task next_sample;
        begin
            @(posedge valid);@(negedge clk);
            if((^pcm)===1'bx || overload || !held_valid)
                $fatal(1,"invalid dynamics PCM");
        end
    endtask
    task setup;
        begin
            @(negedge clk);rst_n=0;on_event=0;off_event=0;param_valid=0;
            repeat(4) @(negedge clk);
            rst_n=1;wait(ready);
            @(negedge clk);param_valid=1;
            @(negedge clk);param_valid=0;
            next_sample;
            on_event=1;@(negedge clk);on_event=0;
        end
    endtask
    task release_key;
        begin off_event=1;@(negedge clk);off_event=0;end
    endtask
    initial begin
        previous_gain=0;
        for(i=0;i<256;i=i+1) begin
            curve_velocity=i;#1;
            if(curve_gain<previous_gain || curve_gain>127)
                $fatal(1,"piano gain discontinuity at %0d",i);
            previous_gain=curve_gain;
        end
        trace=$fopen("waveforms/strike_dynamics.csv","w");
        $fdisplay(trace,"instrument,velocity,index,sample");
        for(t=0;t<3;t=t+1) begin
            timbre=t;
            for(s=0;s<3;s=s+1) begin
                velocity=s==0 ? 32 : s==1 ? 80 : 120;
                setup;
                for(i=0;i<16384;i=i+1) begin
                    next_sample;
                    if(i==8192) release_key;
                    $fdisplay(trace,"%0d,%0d,%0d,%0d",t,velocity,i,pcm);
                end
                if(t!=2 && (active!=0 || pcm!=0))
                    $fatal(1,"piano/guitar damper did not finish");
                if(t==2 && (active!=1 || tapped.a2.key_down!=0))
                    $fatal(1,"bell tap must continue after release");
                $display("PASS capture t=%0d velocity=%0d",t,velocity);
                $fflush();
            end
        end
        $fclose(trace);
        trace=$fopen("waveforms/bell_tap.csv","w");
        $fdisplay(trace,"index,tapped,held");
        timbre=2;velocity=100;setup;
        next_sample;release_key;
        for(i=0;i<48000;i=i+1) begin
            next_sample;
            if(pcm!==held_pcm || active!=1 || tapped.a2.key_down!=0)
                $fatal(1,"bell early tap differs from hold at %0d",i);
            $fdisplay(trace,"%0d,%0d,%0d",i,pcm,held_pcm);
        end
        $fclose(trace);
        wait(envelope_done);
        $display("STRIKE DYNAMICS PASS: gain curve, 9 captures, 1s tap/hold bit-exact, bounded 6s bell");
        $finish;
    end

    reg env_rst=0,env_on=0,env_off=0,envelope_done=0;
    wire [15:0] env_level;
    wire env_active;
    wire [2:0] env_stage;
    integer elapsed;
    adsr #(.ENABLE_TIMBRES(1)) envelope(
        .clk(clk),.rst_n(env_rst),.sample_tick(1'b1),.note_on(env_on),
        .note_off(env_off),.instrument(2'd2),.velocity(8'd32),
        .shared_release_quotient(16'd0),.shared_release_modulus(16'd0),
        .level(env_level),.active(env_active),.stage(env_stage));
    initial begin
        repeat(4) @(negedge clk);env_rst=1;env_on=1;
        @(negedge clk);env_on=0;env_off=1;
        @(negedge clk);env_off=0;
        if(env_stage!=1 || env_level==0)
            $fatal(1,"early NOTE_OFF cut bell attack");
        wait(env_stage==2);@(negedge clk);
        for(elapsed=0;elapsed<288000;elapsed=elapsed+1) begin
            if(!env_active) $fatal(1,"bell prematurely reclaimed at %0d",elapsed);
            @(negedge clk);
        end
        if(env_active || env_level!=0) $fatal(1,"bell exceeded 6s cap");
        env_on=1;@(negedge clk);env_on=0;
        if(!env_active || env_stage!=1) $fatal(1,"bell did not retrigger");
        envelope_done=1;
    end
    initial begin #600000000;$fatal(1,"strike dynamics timeout");end
endmodule

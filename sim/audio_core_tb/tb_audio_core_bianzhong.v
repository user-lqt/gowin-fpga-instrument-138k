`timescale 1ns/1ps
`include "event_defs.vh"
module tb_audio_core_bianzhong;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, sample_tick=0, event_valid=0, param_valid=0;
    reg [1:0] event_type=0;
    reg [6:0] note_id=60;
    reg [7:0] velocity=105;
    reg [3:0] param_id=0;
    reg [15:0] param_value=0;
    wire valid, ready, overload, event_overflow, param_overflow;
    wire signed [23:0] left, right;
    wire [5:0] active;
    integer divider=0, cycle=0, tick_cycle=0, last_valid=0;
    integer trace, i, n, sample_index=0, overlaps=0;
    integer melody [0:14];
    integer duration [0:14];
    reg capturing=0, seen_valid=0;
    reg signed [23:0] held;
    always @(posedge clk) begin
        if (!rst_n) begin divider<=0; sample_tick<=0; end
        else begin divider<=divider==31 ? 0 : divider+1; sample_tick<=divider==31; end
    end
    audio_core #(.VOICE_COUNT(4), .RELEASE_SAMPLES(48000)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .event_valid(event_valid), .event_type(event_type),
        .note_id(note_id), .velocity(velocity),
        .param_valid(param_valid), .param_id(param_id), .param_value(param_value),
        .audio_core_valid(valid), .audio_left(left), .audio_right(right),
        .active_voice_count(active), .engine_ready(ready), .overload_flag(overload),
        .event_overflow(event_overflow), .param_overflow(param_overflow)
    );
    genvar v;
    generate for (v=0; v<4; v=v+1) begin : rail_checks
        always @(posedge clk) begin
            if (rst_n && valid && capturing &&
                (dut.a2.voices[v].u_voice.u_bell.rendered >= 32767 ||
                 dut.a2.voices[v].u_voice.u_bell.rendered <= -32768))
                $fatal(1, "bell internal rail hit");
        end
    end endgenerate
    always @(posedge clk) begin
        cycle=cycle+1;
        if (sample_tick) tick_cycle=cycle;
        #1;
        if (!rst_n) begin last_valid=0; seen_valid=0; end
        else if (valid) begin
            if (cycle-tick_cycle!=22 || (last_valid!=0 && cycle-last_valid!=32))
                $fatal(1, "bell cadence fault");
            if ((^left)===1'bx || left!==right || overload ||
                event_overflow || param_overflow || active>4)
                $fatal(1, "bell PCM/queue fault");
            if (capturing) begin
                $fdisplay(trace,"%0d,%0d,%0d,%0d",sample_index,n,active,left);
                sample_index=sample_index+1;
                if (active>1) overlaps=overlaps+1;
            end
            held=left; seen_valid=1; last_valid=cycle;
        end else if (seen_valid && left!==held) $fatal(1,"bell sample hold");
    end
    task record;
        input integer count;
        begin
            for (i=0;i<count;i=i+1) begin @(posedge valid); @(negedge clk); end
        end
    endtask
    task send_event;
        input [1:0] kind;
        input [6:0] note;
        begin
            @(negedge clk); event_valid=1; event_type=kind; note_id=note;
            @(negedge clk); event_valid=0;
        end
    endtask
    task send_param;
        input [3:0] id;
        input [15:0] value;
        begin
            @(negedge clk); param_valid=1; param_id=id; param_value=value;
            @(negedge clk); param_valid=0; record(2);
        end
    endtask
    initial begin
        melody[0]=64; melody[1]=64; melody[2]=65; melody[3]=67;
        melody[4]=67; melody[5]=65; melody[6]=64; melody[7]=62;
        melody[8]=60; melody[9]=60; melody[10]=62; melody[11]=64;
        melody[12]=64; melody[13]=62; melody[14]=62;
        for(n=0;n<15;n=n+1) duration[n]=31200;
        duration[12]=46800; duration[13]=15600; duration[14]=62400;
        repeat(4) @(negedge clk); rst_n=1;
        record(80);
        send_param(`PARAM_INSTRUMENT,2);
        send_param(`PARAM_VOLUME,16'h5fff);
        record(520);
        if (!ready || dut.instrument!==2 || dut.volume!==16'h5fff)
            $fatal(1,"bell setup");
        trace=$fopen("waveforms/bianzhong_single.csv","w");
        if (!trace) $fatal(1,"cannot open bell single trace");
        $fdisplay(trace,"sample_index,note_index,active,audio");
        n=0; capturing=1;
        send_event(`EVENT_NOTE_ON,60);
        record(144000);
        send_event(`EVENT_NOTE_OFF,60);
        record(57600);
        capturing=0; $fclose(trace);
        if (active!==0 || left!==0 || sample_index!=201600)
            $fatal(1,"bell single release");
        sample_index=0; overlaps=0;
        trace=$fopen("waveforms/bianzhong_ode.csv","w");
        if (!trace) $fatal(1,"cannot open bell melody trace");
        $fdisplay(trace,"sample_index,note_index,active,audio");
        capturing=1;
        for(n=0;n<15;n=n+1) begin
            velocity=n==0 || n==8 ? 108 : 98;
            send_event(`EVENT_NOTE_ON,melody[n]);
            record(duration[n]-480);
            send_event(`EVENT_NOTE_OFF,melody[n]);
            record(480);
        end
        record(57600);
        capturing=0; $fclose(trace);
        if (active!==0 || left!==0 || sample_index!=556800 || overlaps<1000)
            $fatal(1,"bell melody release/overlap");
        $display("BIANZHONG PASS: single 201600 samples, melody 556800 samples");
        $finish;
    end
    initial begin #300_000_000; $fatal(1,"bell timeout"); end
endmodule

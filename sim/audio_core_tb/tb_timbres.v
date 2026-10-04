`timescale 1ns/1ps
`include "event_defs.vh"

module tb_timbres;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg [2:0] tick_count=0;
    wire sample_tick=tick_count==7;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) tick_count<=0;
        else tick_count<=tick_count+1'b1;

    reg event_valid=0, param_valid=0;
    reg [1:0] event_type=0;
    reg [6:0] note_id=0;
    reg [7:0] velocity=0;
    reg [3:0] param_id=0;
    reg [15:0] param_value=0;
    wire audio_core_valid, engine_ready, overload_flag;
    wire event_overflow, param_overflow;
    wire signed [23:0] audio_left, audio_right;
    wire [5:0] active_voice_count;
    integer f, i, clips=0, nonzero, checksum[0:2], peak;
    reg [1:0] mode;
    audio_core dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .event_valid(event_valid), .event_type(event_type),
        .note_id(note_id), .velocity(velocity),
        .param_valid(param_valid), .param_id(param_id), .param_value(param_value),
        .audio_core_valid(audio_core_valid), .audio_left(audio_left),
        .audio_right(audio_right), .active_voice_count(active_voice_count),
        .engine_ready(engine_ready), .overload_flag(overload_flag),
        .event_overflow(event_overflow), .param_overflow(param_overflow)
    );
    always @(posedge clk) if(rst_n && audio_core_valid && overload_flag) clips=clips+1;

    task parameter_event;
        input [3:0] id;
        input [15:0] value;
        begin
            @(negedge clk); param_valid=1; param_id=id; param_value=value;
            @(negedge clk); param_valid=0;
        end
    endtask
    task note_event;
        input [1:0] kind;
        input [6:0] note;
        input [7:0] vel;
        begin
            @(negedge clk); event_valid=1; event_type=kind;
            note_id=note; velocity=vel;
            @(negedge clk); event_valid=0;
        end
    endtask
    task samples;
        input integer count;
        integer n;
        begin
            for(n=0;n<count;n=n+1) begin
                @(posedge audio_core_valid); @(negedge clk);
            end
        end
    endtask

    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        wait(engine_ready);
        parameter_event(`PARAM_VOLUME,16'hffff);
        samples(3);
        for(mode=0;mode<3;mode=mode+1) begin
            parameter_event(`PARAM_INSTRUMENT,{14'd0,mode});
            samples(3);
            if(dut.instrument!==mode) $fatal(1,"instrument parameter not applied");
            note_event(`EVENT_NOTE_ON,7'd60,8'd127);
            samples(3000);
            if(active_voice_count!=1 || dut.a2.voices[0].u_voice.held_instrument!==mode)
                $fatal(1,"new note did not select timbre %0d",mode);
            // A new parameter must not change an already held voice.
            parameter_event(`PARAM_INSTRUMENT,16'd2);
            samples(3);
            if(dut.a2.voices[0].u_voice.held_instrument!==mode)
                $fatal(1,"held note changed timbre");
            parameter_event(`PARAM_INSTRUMENT,{14'd0,mode});
            samples(3);
            f=$fopen(mode==0 ? "waveforms/timbre_sine.txt" :
                     mode==1 ? "waveforms/timbre_triangle.txt" :
                               "waveforms/timbre_saw.txt","w");
            if(!f) $fatal(1,"cannot open timbre output");
            checksum[mode]=0; nonzero=0; peak=0;
            for(i=0;i<48000;i=i+1) begin
                @(posedge audio_core_valid); @(negedge clk);
                $fdisplay(f,"%0d",audio_left >>> 8);
                if(audio_left!=0) nonzero=nonzero+1;
                checksum[mode]=checksum[mode] ^ (audio_left + i);
                if(audio_left>peak) peak=audio_left;
                if(audio_left!==audio_right || overload_flag)
                    $fatal(1,"stereo mismatch or clipping in mode %0d",mode);
            end
            $fclose(f);
            if(nonzero<45000 || peak<500000) $fatal(1,"weak or silent timbre %0d",mode);
            note_event(`EVENT_NOTE_OFF,7'd60,0);
            samples(4808);
            if(active_voice_count!=0 || audio_left!=0) $fatal(1,"release failed");
        end
        if(checksum[0]==checksum[1] || checksum[0]==checksum[2] ||
           checksum[1]==checksum[2]) $fatal(1,"timbres are identical");
        parameter_event(`PARAM_INSTRUMENT,16'd15);
        samples(3);
        if(dut.instrument!=2) $fatal(1,"invalid timbre index changed selection");
        note_event(`EVENT_NOTE_ON,7'd60,127);
        note_event(`EVENT_NOTE_ON,7'd64,127);
        note_event(`EVENT_NOTE_ON,7'd67,127);
        note_event(`EVENT_NOTE_ON,7'd72,127);
        samples(3500);
        if(active_voice_count!=4 || clips!=0 || event_overflow || param_overflow)
            $fatal(1,"four-voice saw chord clipped or overflowed");
        $display("PASS three distinct timbres, held-note switch, release, invalid index and four-voice full-volume chord");
        $finish;
    end
    initial begin #100000000; $fatal(1,"timbre simulation timeout"); end
endmodule

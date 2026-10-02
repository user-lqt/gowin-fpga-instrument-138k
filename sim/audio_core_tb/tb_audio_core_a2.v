`timescale 1ns/1ps
`include "event_defs.vh"

module tb_audio_core_a2;
    reg clk = 0;
    always #40.6901 clk = ~clk;
    reg rst_n = 0;
    reg tick_enable = 1;
    integer tick_count = 0;
    wire sample_tick = tick_enable && tick_count == 255;
    always @(posedge clk or negedge rst_n)
        if (!rst_n || !tick_enable) tick_count <= 0;
        else if (sample_tick) tick_count <= 0;
        else tick_count <= tick_count + 1;

    reg event_valid = 0;
    reg [1:0] event_type = 0;
    reg [6:0] note_id = 0;
    reg [7:0] velocity = 0;
    reg param_valid = 0;
    reg [3:0] param_id = 0;
    reg [15:0] param_value = 0;
    wire audio_core_valid, engine_ready, overload_flag;
    wire event_overflow, param_overflow;
    wire signed [23:0] audio_left, audio_right;
    wire [5:0] active_voice_count;

    audio_core #(.VOICE_COUNT(4), .ENABLE_STEAL(0),
                 .ENABLE_TIMBRES(0), .EVENT_DEPTH(16)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .event_valid(event_valid), .event_type(event_type),
        .note_id(note_id), .velocity(velocity),
        .param_valid(param_valid), .param_id(param_id), .param_value(param_value),
        .audio_core_valid(audio_core_valid), .audio_left(audio_left),
        .audio_right(audio_right), .active_voice_count(active_voice_count),
        .engine_ready(engine_ready), .overload_flag(overload_flag),
        .event_overflow(event_overflow), .param_overflow(param_overflow)
    );

    integer checks = 0;
    integer samples_checked = 0;
    integer scenario = 0;
    integer trace_file;
    integer j;
    integer full_events = 0;
    integer positive_clips = 0;
    integer negative_clips = 0;
    integer release_start;
    reg [2:0] expected_ticks = 0;
    reg expected_valid;
    reg signed [63:0] reference_sum;
    reg signed [63:0] reference_scaled;
    reg signed [23:0] reference_audio;
    reg reference_clip;
    reg signed [23:0] held_audio = 0;

`define CHECK(condition, label) \
    begin \
        checks = checks + 1; \
        if (!(condition)) $fatal(1, "A2 FAIL: %s", label); \
        $display("[PASS] %s", label); \
    end

    task send_event;
        input [1:0] kind;
        input [6:0] n;
        input [7:0] v;
        begin
            @(negedge clk);
            event_valid = 1;
            event_type = kind;
            note_id = n;
            velocity = v;
            @(negedge clk);
            event_valid = 0;
        end
    endtask

    task send_param;
        input [3:0] id;
        input [15:0] value;
        begin
            @(negedge clk);
            param_valid = 1;
            param_id = id;
            param_value = value;
            @(negedge clk);
            param_valid = 0;
        end
    endtask

    task wait_samples;
        input integer count;
        integer n;
        begin
            for (n = 0; n < count; n = n + 1) begin
                @(posedge audio_core_valid);
                #2;
            end
        end
    endtask

    task pause_ticks;
        begin
            @(negedge clk);
            tick_enable = 0;
            repeat (6) @(negedge clk);
        end
    endtask

    task resume_ticks;
        begin
            @(negedge clk);
            tick_enable = 1;
        end
    endtask

    task reset_core;
        begin
            @(negedge clk);
            rst_n = 0;
            event_valid = 0;
            param_valid = 0;
            repeat (4) @(negedge clk);
            `CHECK(audio_left === 0 && audio_right === 0 &&
                   !audio_core_valid && !engine_ready && active_voice_count == 0,
                   "reset clears audio and status");
            rst_n = 1;
            tick_enable = 1;
            repeat (70) @(negedge clk);
            `CHECK(engine_ready && !event_overflow && !param_overflow,
                   "ready and queue status recover after reset");
        end
    endtask

    // Independent 64-bit signed reference; check before and after RTL NBA updates.
    always @(posedge clk) begin
        if (!rst_n) begin
            expected_ticks = 0;
            held_audio = 0;
        end else begin
            expected_valid = expected_ticks[2];
            expected_ticks = {expected_ticks[1:0], sample_tick};
            reference_sum =
                $signed(dut.a2.voice_samples[23:0]) +
                $signed(dut.a2.voice_samples[47:24]) +
                $signed(dut.a2.voice_samples[71:48]) +
                $signed(dut.a2.voice_samples[95:72]);
            reference_scaled = (reference_sum * $signed({1'b0, dut.volume})) >>> 16;
            reference_clip = reference_scaled > 8388607 || reference_scaled < -8388608;
            reference_audio = reference_scaled > 8388607 ? 24'sh7fffff :
                              reference_scaled < -8388608 ? 24'sh800000 :
                              reference_scaled[23:0];
            #1;
            if (audio_core_valid !== expected_valid)
                $fatal(1, "valid latency must be three clocks after sample_tick");
            if ((^{audio_left, audio_right, active_voice_count, overload_flag}) === 1'bx)
                $fatal(1, "unknown output detected");
            if (audio_left !== audio_right)
                $fatal(1, "mono-to-stereo channels differ");
            if (!engine_ready || event_overflow) begin
                if (audio_left !== 0 || overload_flag)
                    $fatal(1, "initialization/fault mute failed");
            end else if (audio_core_valid) begin
                if (audio_left !== reference_audio || overload_flag !== reference_clip)
                    $fatal(1, "mixed sample or clipping status differs from reference");
            end else if (audio_left !== held_audio)
                $fatal(1, "sample changed outside valid pulse");
            held_audio = audio_left;
            if (dut.a2.full_pulse) full_events = full_events + 1;
            if (audio_core_valid) begin
                samples_checked = samples_checked + 1;
                if (overload_flag && audio_left == 24'sh7fffff)
                    positive_clips = positive_clips + 1;
                if (overload_flag && audio_left == 24'sh800000)
                    negative_clips = negative_clips + 1;
                $fdisplay(trace_file,
                    "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                    samples_checked, scenario, audio_left, dut.volume,
                    active_voice_count, overload_flag, event_overflow, param_overflow,
                    dut.a2.envelope_levels[15:0], dut.a2.envelope_levels[31:16],
                    dut.a2.envelope_levels[47:32], dut.a2.envelope_levels[63:48],
                    dut.a2.envelope_stages[2:0], dut.a2.envelope_stages[5:3],
                    dut.a2.envelope_stages[8:6], dut.a2.envelope_stages[11:9],
                    dut.a2.voices[0].u_voice.u_oscillator.u_phase_acc.phase,
                    dut.a2.voices[1].u_voice.u_oscillator.u_phase_acc.phase,
                    dut.a2.voices[2].u_voice.u_oscillator.u_phase_acc.phase,
                    dut.a2.voices[3].u_voice.u_oscillator.u_phase_acc.phase,
                    dut.a2.voice_velocity[7:0], dut.a2.voice_velocity[15:8],
                    dut.a2.voice_velocity[23:16], dut.a2.voice_velocity[31:24],
                    dut.a2.voice_note_id[6:0], dut.a2.voice_note_id[13:7],
                    dut.a2.voice_note_id[20:14], dut.a2.voice_note_id[27:21],
                    dut.ev_count, dut.p_count);
            end
        end
    end

    initial begin
        trace_file = $fopen("waveforms/a2_samples.csv", "w");
        if (!trace_file) $fatal(1, "cannot open sample trace");
        $fdisplay(trace_file, "sample,scenario,audio,volume,count,clip,event_overflow,param_overflow,env0,env1,env2,env3,stage0,stage1,stage2,stage3,phase0,phase1,phase2,phase3,vel0,vel1,vel2,vel3,note0,note1,note2,note3,event_count,param_count");
        $dumpfile("waveforms/tb_audio_core_a2.vcd");
        $dumpvars(0, sample_tick, audio_core_valid, audio_left, audio_right,
            engine_ready, active_voice_count, overload_flag, event_overflow,
            param_overflow, event_valid, event_type, note_id, velocity,
            param_valid, param_id, param_value, scenario,
            dut.a2.envelope_levels, dut.a2.envelope_stages,
            dut.a2.voice_samples, dut.a2.key_down, dut.a2.voice_note_on,
            dut.a2.voice_note_off, dut.volume, dut.ev_count, dut.p_count);

        reset_core();
        scenario = 1;
        wait_samples(8);
        `CHECK(audio_left == 0 && active_voice_count == 0, "idle stays silent");
        `CHECK(dut.volume == 16'h3fff, "default gain reserves four-voice headroom");
        pause_ticks();
        send_event(`EVENT_NOTE_ON, 60, 100);
        send_event(`EVENT_NOTE_ON, 64, 90);
        send_event(`EVENT_NOTE_ON, 67, 80);
        send_event(`EVENT_NOTE_ON, 69, 70);
        `CHECK(dut.ev_count == 4 && active_voice_count == 0, "burst waits in FIFO");
        scenario = 2;
        resume_ticks();
        wait_samples(4);
        `CHECK(active_voice_count == 4 && dut.ev_count == 0, "four queued notes become independent voices");
        `CHECK(dut.a2.voice_note_id == {7'd69,7'd67,7'd64,7'd60}, "FIFO order reaches allocator");
        wait_samples(3200);
        `CHECK(dut.a2.envelope_stages == {4{3'd3}}, "all four voices reach sustain");
        wait_samples(4096);
        `CHECK(positive_clips == 0 && negative_clips == 0, "default gain avoids chord clipping");

        scenario = 3;
        send_event(`EVENT_NOTE_ON, 72, 127);
        wait_samples(1);
        `CHECK(full_events == 1 && active_voice_count == 4 &&
               dut.a2.voice_note_id == {7'd69,7'd67,7'd64,7'd60},
               "fifth note is rejected without stealing or stopping voices");
        send_event(`EVENT_NOTE_ON, 64, 127);
        wait_samples(1);
        `CHECK(active_voice_count == 4 && dut.a2.envelope_stages[5:3] == 1 &&
               dut.a2.envelope_levels[31:16] != 0,
               "held-note retrigger keeps envelope continuous");
        send_event(`EVENT_NOTE_OFF, 90, 0);
        send_event(`EVENT_NOTE_ON, 60, 0);
        wait_samples(2);
        `CHECK(active_voice_count == 4 && dut.a2.key_down == 4'b1111,
               "unknown off and zero velocity leave chord intact");
        wait_samples(3200);

        scenario = 4;
        send_param(`PARAM_VOLUME, 0);
        wait_samples(4);
        `CHECK(audio_left == 0 && active_voice_count == 4, "zero gain mutes without killing voices");
        send_param(`PARAM_VOLUME, 16'h8000);
        wait_samples(4);
        `CHECK(dut.volume == 16'h8000, "volume update applies on sample tick");
        send_param(`PARAM_VOLUME, 16'h3fff);
        wait_samples(4);

        scenario = 5;
        send_event(`EVENT_NOTE_OFF, 64, 0);
        wait_samples(1);
        release_start = dut.a2.envelope_levels[31:16];
        `CHECK(active_voice_count == 4 && dut.a2.envelope_stages[5:3] == 4 &&
               release_start == 45875, "note off preserves level and counts releasing voice");
        send_event(`EVENT_NOTE_ON, 72, 127);
        wait_samples(1);
        `CHECK(full_events == 2 && dut.a2.voice_note_id[13:7] == 64,
               "release tail is not stolen by a new note");
        wait_samples(2399);
        `CHECK(dut.a2.envelope_levels[31:16] > 0 &&
               dut.a2.envelope_stages[2:0] == 3 &&
               dut.a2.envelope_stages[8:6] == 3 &&
               dut.a2.envelope_stages[11:9] == 3, "one release does not alter other envelopes");
        wait_samples(2399);
        `CHECK(active_voice_count == 4 && dut.a2.envelope_levels[31:16] > 0,
               "release remains active through sample 4799");
        wait_samples(1);
        `CHECK(active_voice_count == 3 && dut.a2.envelope_levels[31:16] == 0,
               "release completes at exactly 4800 samples");
        send_event(`EVENT_NOTE_ON, 72, 127);
        wait_samples(1);
        `CHECK(active_voice_count == 4 && dut.a2.voice_note_id[13:7] == 72,
               "completed release slot can be reused");
        send_event(`EVENT_NOTE_OFF, 60, 0);
        send_event(`EVENT_NOTE_OFF, 72, 0);
        send_event(`EVENT_NOTE_OFF, 67, 0);
        send_event(`EVENT_NOTE_OFF, 69, 0);
        scenario = 6;
        wait_samples(4804);
        `CHECK(active_voice_count == 0 && audio_left == 0, "all release tails finish at silence");

        scenario = 7;
        send_event(`EVENT_NOTE_ON, 72, 127);
        wait_samples(10);
        send_event(`EVENT_NOTE_OFF, 72, 0);
        wait_samples(1);
        release_start = dut.a2.envelope_levels[15:0];
        `CHECK(release_start > 0 && release_start < 4800, "early off starts from low attack level");
        wait_samples(4799);
        `CHECK(active_voice_count == 1 && dut.a2.envelope_levels[15:0] > 0,
               "low-level release also lasts full configured duration");
        wait_samples(1);
        `CHECK(active_voice_count == 0 && audio_left == 0, "early release finishes without underflow");
        send_event(`EVENT_NOTE_ON, 65, 255);
        wait_samples(20);
        `CHECK(active_voice_count == 1, "out-of-range velocity is safely clamped");

        scenario = 8;
        reset_core();
        send_event(`EVENT_NOTE_ON, 69, 127);
        send_event(`EVENT_NOTE_ON, 70, 127);
        send_event(`EVENT_NOTE_ON, 71, 127);
        send_event(`EVENT_NOTE_ON, 72, 127);
        wait_samples(500);
        `CHECK(active_voice_count == 4 && positive_clips == 0 && negative_clips == 0,
               "maximum-velocity chord stays bounded at default gain");
        scenario = 9;
        send_param(`PARAM_VOLUME, 16'hffff);
        wait_samples(2000);
        `CHECK(positive_clips > 0 && negative_clips > 0,
               "intentional overload saturates at both signed rails");

        scenario = 10;
        pause_ticks();
        for (j = 0; j < 4; j = j + 1) send_param(`PARAM_VOLUME, 1234 + j);
        send_param(`PARAM_VOLUME, 16'hf000);
        `CHECK(param_overflow && !event_overflow && dut.p_count == 4,
               "parameter overflow is sticky and preserves queued updates");
        resume_ticks();
        wait_samples(4);
        `CHECK(dut.volume == 1237 && dut.p_count == 0 && active_voice_count == 4,
               "parameter overflow does not kill voices or overwrite FIFO");

        scenario = 11;
        pause_ticks();
        for (j = 0; j < 16; j = j + 1) send_event(`EVENT_NOTE_ON, 69, 80);
        `CHECK(dut.ev_count == 16 && !event_overflow, "full event FIFO holds sixteen entries");
        resume_ticks();
        @(negedge clk);
        while (!sample_tick) @(negedge clk);
        event_valid = 1;
        event_type = `EVENT_NOTE_OFF;
        note_id = 69;
        velocity = 0;
        @(negedge clk);
        event_valid = 0;
        `CHECK(dut.ev_count == 16 && !event_overflow, "full FIFO accepts simultaneous pop and push");
        wait_samples(17);
        `CHECK(dut.ev_count == 0 && !dut.a2.key_down[0] &&
               dut.a2.envelope_stages[2:0] == 4,
               "collision NOTE_OFF remains ordered behind queued NOTE_ONs");
        send_event(`EVENT_NONE, 0, 0);
        send_param(15, 16'hffff);
        wait_samples(1);
        `CHECK(dut.volume == 1237 && active_voice_count == 4,
               "reserved event and parameter have no side effects");
        pause_ticks();
        // Empty-queue bypass: note and parameter presented on the same sample edge.
        resume_ticks();
        @(negedge clk);
        while (!sample_tick) @(negedge clk);
        event_valid = 1;
        event_type = `EVENT_NOTE_OFF;
        note_id = 70;
        param_valid = 1;
        param_id = `PARAM_VOLUME;
        param_value = 16'h2000;
        @(negedge clk);
        event_valid = 0;
        param_valid = 0;
        wait_samples(1);
        `CHECK(dut.ev_count == 0 && dut.p_count == 0 &&
               dut.volume == 16'h2000 && dut.a2.envelope_stages[5:3] == 4,
               "empty event and parameter queues bypass without replay");

        scenario = 12;
        pause_ticks();
        for (j = 0; j < 17; j = j + 1) send_event(`EVENT_NOTE_ON, 60 + j, 80);
        `CHECK(event_overflow && active_voice_count == 0 &&
               audio_left == 0 && dut.ev_count == 0, "event overflow immediately mutes and clears FIFO");
        resume_ticks();
        wait_samples(8);
        `CHECK(event_overflow && audio_left == 0 && active_voice_count == 0,
               "event fault mute persists until reset");
        scenario = 13;
        reset_core();
        wait_samples(4);
        `CHECK(audio_left == 0 && active_voice_count == 0, "reset recovers to silent idle");
        $fclose(trace_file);
        $display("A2 INTEGRATION PASS (%0d/%0d scenarios, %0d samples checked, clips +%0d/-%0d)",
                 checks, checks, samples_checked, positive_clips, negative_clips);
        $finish;
    end

    initial begin
        #1_500_000_000;
        $fatal(1, "A2 integration timeout");
    end
endmodule

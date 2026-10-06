`timescale 1ns/1ps
`include "event_defs.vh"

module tb_audio_core_a3 #(parameter integer SAMPLE_CLOCKS=256);
    // Absolute simulation time is accelerated; the hardware cycle ratio is 256.
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg sample_tick = 0;
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
    integer ticks = 0;
    integer checks = 0;
    integer i, j, n, matches, victim, expected_note;
    integer cycles = 0, last_valid = 0, last_tick = 0, sample_count = 0;
    integer clipped = 0;
    integer capture;
    localparam integer TIMBRE_SAMPLES = 128;
    integer samples [0:4*TIMBRE_SAMPLES-1];
    integer different01, different02, different12;
    reg [63:0] energy [0:3];
    reg [63:0] measured_energy;
    reg signed [31:0] sample_value;
    reg signed [63:0] square;
    reg signed [23:0] previous_audio;
    reg monitor_hold = 0;
    reg [31:0] previous_phase [0:31];
    wire [1023:0] phases;
    wire [1023:0] frequencies;
    genvar g;
    generate for (g = 0; g < 32; g = g + 1) begin : probes
        assign phases[g*32 +: 32] =
            dut.a2.voices[g].u_voice.u_oscillator.u_phase_acc.phase;
        assign frequencies[g*32 +: 32] = dut.a2.voices[g].u_voice.fc;
    end endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            sample_tick <= 0;
            ticks <= 0;
        end else if (ticks == SAMPLE_CLOCKS-1) begin
            sample_tick <= 1;
            ticks <= 0;
        end else begin
            sample_tick <= 0;
            ticks <= ticks + 1;
        end
    end

    audio_core #(
        .ATTACK_SAMPLES(8),
        .DECAY_SAMPLES(16),
        .RELEASE_SAMPLES(64)
    ) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .event_valid(event_valid), .event_type(event_type),
        .note_id(note_id), .velocity(velocity),
        .param_valid(param_valid), .param_id(param_id), .param_value(param_value),
        .audio_core_valid(audio_core_valid), .audio_left(audio_left),
        .audio_right(audio_right), .active_voice_count(active_voice_count),
        .engine_ready(engine_ready), .overload_flag(overload_flag),
        .event_overflow(event_overflow), .param_overflow(param_overflow)
    );

    `define CHECK(c, text) begin \
        checks = checks + 1; \
        if ((c) !== 1'b1) $fatal(1, "A3 FAIL: %s", text); \
        $display("[PASS] %s", text); $fflush(); \
    end

    task reset_core;
        begin
            @(negedge clk);
            rst_n = 0;
            event_valid = 1;
            param_valid = 1;
            repeat (4) @(negedge clk);
            if (audio_left !== 0 || active_voice_count !== 0)
                $fatal(1, "reset did not mute output");
            event_valid = 0;
            param_valid = 0;
            rst_n = 1;
            repeat (80) @(negedge clk);
        end
    endtask

    task send_event;
        input [1:0] kind;
        input [6:0] note;
        input [7:0] vel;
        begin
            @(negedge clk);
            event_valid = 1; event_type = kind; note_id = note; velocity = vel;
            @(negedge clk);
            event_valid = 0;
        end
    endtask

    task send_param;
        input [3:0] id;
        input [15:0] value;
        begin
            @(negedge clk);
            param_valid = 1; param_id = id; param_value = value;
            @(negedge clk);
            param_valid = 0;
        end
    endtask

    task wait_samples;
        input integer count;
        integer s;
        begin
            for (s = 0; s < count; s = s + 1) begin
                @(posedge audio_core_valid);
                @(negedge clk);
            end
        end
    endtask

    task measure;
        input integer count;
        integer s;
        begin
            measured_energy = 0;
            for (s = 0; s < count; s = s + 1) begin
                wait_samples(1);
                sample_value = audio_left;
                square = sample_value * sample_value;
                measured_energy = measured_energy + square;
            end
        end
    endtask

    // Check every emitted sample, not merely the final state of each scenario.
    always @(posedge clk) begin
        cycles = cycles + 1;
        if (rst_n && sample_tick) last_tick = cycles;
        #1;
        if (!rst_n) begin
            last_valid = 0;
            monitor_hold = 0;
        end else if (audio_core_valid) begin
            if (cycles - last_tick != 109)
                $fatal(1, "sample latency is not 109 clocks");
            if (last_valid != 0 && cycles - last_valid != SAMPLE_CLOCKS)
                $fatal(1, "dropped or duplicated audio sample");
            if ((^audio_left) === 1'bx || audio_left !== audio_right)
                $fatal(1, "unknown sample or stereo mismatch");
            last_valid = cycles;
            sample_count = sample_count + 1;
            if (overload_flag) clipped = clipped + 1;
            previous_audio = audio_left;
            monitor_hold = 1;
        end else if (monitor_hold && !event_overflow && audio_left !== previous_audio)
            $fatal(1, "output changed between valid pulses");
    end

    initial begin
        capture = $fopen("waveforms/a3_samples.csv", "w");
        if (!capture) $fatal(1, "cannot open sample capture");
        $fdisplay(capture, "scenario,index,sample");
        reset_core;
        `CHECK(engine_ready && !event_overflow && !param_overflow,
               "A3 ready, reset discards incoming events");
        for (i = 0; i < 32; i = i + 1)
            send_event(`EVENT_NOTE_ON, 48 + i, 127);
        wait_samples(40);
        `CHECK(active_voice_count == 32, "32 independent voices active");
        for (i = 0; i < 32; i = i + 1) begin
            `CHECK(dut.a2.voice_note_id[i*7 +: 7] == 48+i,
                   "voice owns expected distinct note");
            previous_phase[i] = phases[i*32 +: 32];
        end
        wait_samples(1);
        for (i = 0; i < 32; i = i + 1)
            `CHECK((phases[i*32 +: 32] - previous_phase[i]) ==
                   frequencies[i*32 +: 32], "independent phase advances by own frequency");

        // Capture a full-load multi-frequency passage for offline spectral checks.
        wait_samples(128);
        for (n = 0; n < 128; n = n + 1) begin
            wait_samples(1);
            $fdisplay(capture, "poly32,%0d,%0d", n, audio_left);
        end
        `CHECK(clipped == 0, "default volume leaves full-load headroom");

        // Identical envelopes/ages ordering: oldest piano has decayed the most.
        send_event(`EVENT_NOTE_ON, 90, 127);
        wait_samples(2);
        `CHECK(dut.a2.voice_note_id[6:0] == 90 && active_voice_count == 32,
               "33rd note steals oldest quietest held voice");
        send_event(`EVENT_NOTE_OFF, 48, 0);
        wait_samples(2);
        `CHECK(dut.a2.key_down[0], "stale note-off cannot release replacement");
        send_event(`EVENT_NOTE_ON, 90, 80);
        wait_samples(2);
        `CHECK(active_voice_count == 32 && dut.a2.voice_velocity[7:0] == 80,
               "repeated note retriggers same slot");
        send_event(`EVENT_NOTE_OFF, 79, 0);
        wait_samples(2);
        send_event(`EVENT_NOTE_ON, 91, 127);
        wait_samples(2);
        `CHECK(dut.a2.voice_note_id[31*7 +: 7] == 91,
               "released voice is stolen before held voices");
        for (i = 0; i < 32; i = i + 1)
            send_event(`EVENT_NOTE_OFF, dut.a2.voice_note_id[i*7 +: 7], 0);
        wait_samples(100);
        `CHECK(active_voice_count == 0 && audio_left == 0,
               "all 32 release tails end in silence");

        // Compare the same pitch, velocity, start phase and capture interval.
        for (j = 0; j < 4; j = j + 1) begin
            reset_core;
            send_param(`PARAM_INSTRUMENT, j);
            wait_samples(2);
            send_event(`EVENT_NOTE_ON, 69, 100);
            wait_samples(80);
            `CHECK(dut.a2.voice_instrument[1:0] == j,
                   "new note latches selected instrument");
            energy[j] = 0;
            for (n = 0; n < TIMBRE_SAMPLES; n = n + 1) begin
                wait_samples(1);
                samples[j*TIMBRE_SAMPLES+n] = audio_left;
                sample_value = audio_left;
                square = sample_value * sample_value;
                energy[j] = energy[j] + square;
                $fdisplay(capture, "timbre%0d,%0d,%0d", j, n, audio_left);
            end
            `CHECK(energy[j] > 0, "instrument produces nonzero PCM");
            send_param(`PARAM_INSTRUMENT, (j+1)%4);
            wait_samples(2);
            `CHECK(dut.a2.voice_instrument[1:0] == j,
                   "held voice retains its instrument on global switch");
        end
        different01 = 0; different02 = 0; different12 = 0;
        for (n = 0; n < TIMBRE_SAMPLES; n = n + 1) begin
            if (samples[n] != samples[TIMBRE_SAMPLES+n]) different01 = different01 + 1;
            if (samples[n] != samples[2*TIMBRE_SAMPLES+n]) different02 = different02 + 1;
            if (samples[TIMBRE_SAMPLES+n] != samples[2*TIMBRE_SAMPLES+n]) different12 = different12 + 1;
        end
        `CHECK(different01 > 90 && different02 > 90 && different12 > 90,
               "all three instrument pairs differ at equal pitch");
        different01 = 0;
        for (n = 0; n < TIMBRE_SAMPLES; n = n + 1)
            if (samples[n] != samples[3*TIMBRE_SAMPLES+n])
                different01 = different01 + 1;
        `CHECK(different01 > 90, "guitar differs from piano at equal pitch");
        send_param(`PARAM_INSTRUMENT, 16'h0010);
        wait_samples(2);
        `CHECK(dut.instrument == 0, "out-of-range full-word instrument falls back");

        reset_core;
        send_param(`PARAM_INSTRUMENT, 1);
        wait_samples(2);
        send_event(`EVENT_NOTE_ON, 69, 127);
        wait_samples(300);
        send_param(`PARAM_VOLUME, 0);
        wait_samples(40);
        measure(32);
        `CHECK(measured_energy == 0 && active_voice_count == 1,
               "zero volume mutes without losing voice");
        for (j = 0; j < 3; j = j + 1) begin
            send_param(`PARAM_VOLUME, 2048 << j);
            wait_samples(140);
            send_event(`EVENT_NOTE_ON, 69, 127);
            wait_samples(80);
            measure(64);
            energy[j] = measured_energy;
            $display("GAIN energy[%0d]=%0d",j,measured_energy); $fflush();
        end
        `CHECK(energy[0] > 0 && energy[1] > energy[0]*3 &&
               energy[2] > energy[1]*3, "volume increases RMS monotonically");
        send_param(`PARAM_VOLUME, 0);
        wait_samples(140);
        measure(32);
        `CHECK(measured_energy == 0, "volume returns to silence");

        for (j = 0; j < 3; j = j + 1) begin
            reset_core;
            send_event(`EVENT_NOTE_ON, 69, 32 + j*40);
            wait_samples(100);
            measure(64);
            energy[j] = measured_energy;
        end
        `CHECK(energy[0] > 0 && energy[1] > energy[0] && energy[2] > energy[1],
               "light medium heavy velocities increase attack energy");

        for (j = 0; j < 3; j = j + 1) begin
            reset_core;
            send_param(`PARAM_INSTRUMENT, 3);
            wait_samples(2);
            send_event(`EVENT_NOTE_ON, 60, 32 + j*40);
            wait_samples(100);
            measure(64);
            energy[j] = measured_energy;
        end
        `CHECK(energy[0] > 0 && energy[1] > energy[0] && energy[2] > energy[1],
               "guitar light medium heavy velocities increase energy");
        reset_core;
        send_param(`PARAM_INSTRUMENT, 3);
        wait_samples(2);
        for (i = 0; i < 32; i = i + 1)
            send_event(`EVENT_NOTE_ON, 48+i, 127);
        wait_samples(300);
        `CHECK(active_voice_count == 32 && !overload_flag &&
               dut.a2.voice_instrument == {32{2'd3}},
               "guitar supports 32 voices at default gain");
        for (i = 0; i < 32; i = i + 1)
            send_event(`EVENT_NOTE_OFF, 48+i, 0);
        wait_samples(100);
        `CHECK(active_voice_count == 0 && audio_left == 0,
               "all 32 guitar release tails end in silence");

        reset_core;
        send_param(`PARAM_INSTRUMENT, 1);
        send_param(`PARAM_VOLUME, 65535);
        wait_samples(2);
        for (i = 0; i < 32; i = i + 1)
            send_event(`EVENT_NOTE_ON, 48+i, 127);
        wait_samples(1100);
        clipped = 0;
        measure(256);
        `CHECK(clipped > 0 && active_voice_count == 32,
               "maximum load clips diagnostically without dropping samples");
        `CHECK(!event_overflow && !param_overflow, "legal bursts do not overflow queues");
        reset_core;
        `CHECK(dut.instrument == 0 && dut.volume == 16'h07ff && audio_left == 0,
               "reset restores piano default volume and silence");
        send_event(`EVENT_NOTE_ON, 60, 100);
        wait_samples(128);
        measure(32);
        `CHECK(measured_energy > 0, "fresh note sounds after reset");
        $fclose(capture);
        $display("A3 INTEGRATION PASS (%0d checks, %0d samples)", checks, sample_count);
        $finish;
    end

    initial begin
        #200_000_000;
        $fatal(1, "A3 integration timeout");
    end
endmodule

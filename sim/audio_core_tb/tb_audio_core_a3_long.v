`timescale 1ns/1ps
`include "event_defs.vh"

module tb_audio_core_a3_long;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg sample_tick = 0;
    reg event_valid = 0;
    reg [1:0] event_type = 0;
    reg [6:0] note_id = 0;
    reg [7:0] velocity = 127;
    reg param_valid = 0;
    reg [3:0] param_id = `PARAM_INSTRUMENT;
    reg [15:0] param_value = 2;
    wire audio_core_valid, engine_ready, overload_flag, event_overflow, param_overflow;
    wire signed [23:0] audio_left, audio_right;
    wire [5:0] active_voice_count;
    integer divider = 0, cycle = 0, tick_cycle = 0, previous_valid = 0;
    integer total_samples = 0;
    integer trace, state_trace;
    integer i, s, k, n, release_total = 0;
    integer release_ticks [0:31];
    integer release_start [0:31];
    integer release_expected;
    reg [15:0] prior_env [0:31];
    reg [31:0] prior_phase [0:31];
    reg [31:0] released = 0, completed = 0;
    wire [1023:0] phases, frequencies;
    reg signed [63:0] reference_sum, reference_scaled;
    reg signed [23:0] reference_audio;
    reg reference_overload;
    reg signed [23:0] last_audio = 0;
    reg have_audio = 0;
    genvar v;
    generate for (v = 0; v < 32; v = v + 1) begin : probes
        assign phases[v*32 +: 32] =
            dut.a2.voices[v].u_voice.u_oscillator.u_phase_acc.phase;
        assign frequencies[v*32 +: 32] = dut.a2.voices[v].u_voice.fc;
    end endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            divider <= 0;
            sample_tick <= 0;
        end else begin
            divider <= divider == 255 ? 0 : divider + 1;
            sample_tick <= divider == 255;
        end
    end

    // No overrides: this is the production 32-voice configuration.
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

    task send_event;
        input [1:0] kind;
        input [6:0] note;
        begin
            @(negedge clk);
            event_valid = 1; event_type = kind; note_id = note;
            @(negedge clk);
            event_valid = 0;
        end
    endtask

    task next_sample;
        begin
            @(posedge audio_core_valid);
            @(negedge clk);
        end
    endtask

    // Sample after NBA updates; assert both the interface timing and mixer math.
    always @(posedge clk) begin
        cycle = cycle + 1;
        if (sample_tick) tick_cycle = cycle;
        #1;
        if (rst_n && engine_ready) begin
            if (cycle - tick_cycle == 78) begin
                reference_sum = 0;
                for (k = 0; k < 32; k = k + 1)
                    reference_sum = reference_sum + $signed(dut.a2.voice_samples[k*24 +: 24]);
                reference_scaled = (reference_sum * $signed({1'b0, dut.volume})) >>> 16;
                reference_overload = reference_scaled > 8388607 || reference_scaled < -8388608;
                reference_audio = reference_scaled > 8388607 ? 24'sh7fffff :
                                  reference_scaled < -8388608 ? 24'sh800000 :
                                  reference_scaled[23:0];
            end
            if (audio_core_valid) begin
                if (cycle - tick_cycle != 109 ||
                    (previous_valid != 0 && cycle - previous_valid != 256))
                    $fatal(1, "A3 long sample latency/cadence mismatch");
                if ((^audio_left) === 1'bx || audio_left !== audio_right ||
                    audio_left !== reference_audio || overload_flag !== reference_overload)
                    $fatal(1, "A3 long signed mixer/stereo mismatch");
                if (overload_flag || event_overflow || param_overflow)
                    $fatal(1, "A3 long unexpected clipping or queue fault");
                previous_valid = cycle;
                total_samples = total_samples + 1;
                last_audio = audio_left;
                have_audio = 1;
            end else if (have_audio && audio_left !== last_audio)
                $fatal(1, "A3 long output not held between valid pulses");
        end
    end

    initial begin
        trace = $fopen("waveforms/a3_poly32.csv", "w");
        state_trace = $fopen("waveforms/a3_poly32_state.csv", "w");
        if (!trace || !state_trace) $fatal(1, "cannot open poly32 captures");
        $fwrite(trace, "index,audio");
        for (i = 0; i < 32; i = i + 1) $fwrite(trace, ",voice%0d", i);
        $fwrite(trace, "\n");
        $fdisplay(state_trace, "index,slot,note,fc,phase,env,stage,active");
        for (i = 0; i < 32; i = i + 1) begin
            release_ticks[i] = 0;
            release_start[i] = 0;
        end
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (80) @(negedge clk);
        if (!engine_ready) $fatal(1, "A3 long engine not ready");
        @(negedge clk); param_valid = 1;
        @(negedge clk); param_valid = 0;
        repeat (2) next_sample;
        for (i = 0; i < 32; i = i + 1) send_event(`EVENT_NOTE_ON, 48+i);
        repeat (400) next_sample;
        if (active_voice_count !== 32 || dut.volume !== 16'h07ff)
            $fatal(1, "A3 long default 32-voice setup failed");
        for (i = 0; i < 32; i = i + 1) prior_phase[i] = phases[i*32 +: 32];

        // Per-voice taps prevent octave harmonics being counted as voices.
        for (s = 0; s < 4096; s = s + 1) begin
            next_sample;
            if (active_voice_count !== 32) $fatal(1, "A3 long lost held voice");
            $fwrite(trace, "%0d,%0d", s, audio_left);
            for (i = 0; i < 32; i = i + 1) begin
                if (dut.a2.voice_note_id[i*7 +: 7] !== 48+i ||
                    (phases[i*32 +: 32] - prior_phase[i]) !== frequencies[i*32 +: 32] ||
                    dut.a2.envelope_levels[i*16 +: 16] == 0)
                    $fatal(1, "A3 long slot %0d state/phase mismatch", i);
                prior_phase[i] = phases[i*32 +: 32];
                $fwrite(trace, ",%0d", $signed(dut.a2.voice_samples[i*24 +: 24]));
                if (s == 0 || s == 4095)
                    $fdisplay(state_trace, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                        s, i, dut.a2.voice_note_id[i*7 +: 7], frequencies[i*32 +: 32],
                        phases[i*32 +: 32], dut.a2.envelope_levels[i*16 +: 16],
                        dut.a2.envelope_stages[i*3 +: 3], dut.a2.voice_active[i]);
            end
            $fwrite(trace, "\n");
        end
        $fflush(trace);
        $display("[PASS] 4096 full-load samples: 32 phases, mixer reference, 109/256 cadence");
        for (i = 0; i < 32; i = i + 1) send_event(`EVENT_NOTE_OFF, 48+i);
        for (s = 0; s < 4835; s = s + 1) begin
            next_sample;
            for (i = 0; i < 32; i = i + 1) begin
                if (dut.a2.envelope_stages[i*3 +: 3] == 4) begin
                    if (!released[i]) begin
                        released[i] = 1;
                        release_start[i] = dut.a2.envelope_levels[i*16 +: 16];
                        prior_env[i] = release_start[i];
                    end
                    release_expected = release_start[i] -
                                       (release_start[i] * release_ticks[i]) / 4800;
                    if (dut.a2.envelope_levels[i*16 +: 16] !== release_expected ||
                        dut.a2.envelope_levels[i*16 +: 16] > prior_env[i])
                        $fatal(1, "A3 long release ramp mismatch at slot %0d", i);
                    prior_env[i] = dut.a2.envelope_levels[i*16 +: 16];
                    release_ticks[i] = release_ticks[i] + 1;
                end else if (released[i] && !completed[i]) begin
                    if (release_ticks[i] != 4800 ||
                        dut.a2.envelope_levels[i*16 +: 16] !== 0 ||
                        dut.a2.voice_active[i] !== 0)
                        $fatal(1, "A3 long slot %0d release count %0d", i, release_ticks[i]);
                    completed[i] = 1;
                    release_total = release_total + 1;
                end
            end
        end
        if (release_total != 32 || active_voice_count !== 0 || audio_left !== 0)
            $fatal(1, "A3 long default release did not finish all voices");
        $display("[PASS] all 32 voices release for exactly 4800 ticks and reach zero");
        $fclose(trace); $fclose(state_trace);
        $display("A3 LONG PASS: %0d valid samples, production defaults", total_samples);
        $finish;
    end
    initial begin
        #200_000_000;
        $fatal(1, "A3 long timeout");
    end
endmodule

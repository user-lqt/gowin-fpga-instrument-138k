`timescale 1ns/1ps
`include "event_defs.vh"

module tb_audio_core_guitar;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, sample_tick = 0, event_valid = 0, param_valid = 0;
    reg [1:0] event_type = 0;
    reg [6:0] note_id = 69;
    reg [7:0] velocity = 100;
    reg [3:0] param_id = 0;
    reg [15:0] param_value = 0;
    wire valid, ready, overload, event_overflow, param_overflow;
    wire signed [23:0] left, right;
    wire [5:0] active;
    integer divider = 0, cycle = 0, tick_cycle = 0, last_valid = 0;
    integer trace, instrument, segment, offset, i, j, slot;
    integer release_ticks [0:3];
    reg [3:0] released, completed;
    reg [6:0] chord [0:3];
    reg signed [23:0] held;
    reg seen = 0;
    genvar probe;
    generate for (probe = 0; probe < 4; probe = probe + 1) begin : probes
        always @(negedge clk) begin
            if (rst_n && valid &&
                dut.a2.voice_instrument[probe*2 +: 2] == 3 &&
                dut.a2.voice_active[probe]) begin
                if (dut.a2.voices[probe].u_voice.guitar.u_string.output_sample > 32767 ||
                    dut.a2.voices[probe].u_voice.guitar.u_string.output_sample < -32768 ||
                    dut.a2.shared_arithmetic.filters[0].u_body_bank.tone[probe] > 32767 ||
                    dut.a2.shared_arithmetic.filters[0].u_body_bank.tone[probe] < -32768)
                    $fatal(1, "guitar internal waveform clipping");
            end
        end
    end endgenerate
    always @(posedge clk) begin
        if (!rst_n) begin divider <= 0; sample_tick <= 0; end
        else begin
            divider <= divider == 255 ? 0 : divider + 1;
            sample_tick <= divider == 255;
        end
    end
    // Accelerated simulation pacing only; PCM sample rate remains 48 kHz.
    audio_core #(.VOICE_COUNT(4)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .event_valid(event_valid), .event_type(event_type),
        .note_id(note_id), .velocity(velocity),
        .param_valid(param_valid), .param_id(param_id), .param_value(param_value),
        .audio_core_valid(valid), .audio_left(left), .audio_right(right),
        .active_voice_count(active), .engine_ready(ready), .overload_flag(overload),
        .event_overflow(event_overflow), .param_overflow(param_overflow)
    );
    always @(posedge clk) begin
        cycle = cycle + 1;
        if (sample_tick) tick_cycle = cycle;
        #1;
        if (!rst_n) begin last_valid = 0; seen = 0; end
        else if (valid) begin
            if (cycle - tick_cycle != 81 ||
                (last_valid != 0 && cycle - last_valid != 256))
                $fatal(1, "guitar sample latency/cadence");
            if ((^left) === 1'bx || left !== right || overload ||
                event_overflow || param_overflow)
                $fatal(1, "guitar PCM or queue fault");
            last_valid = cycle; held = left; seen = 1;
        end else if (seen && held !== left) $fatal(1, "guitar output hold");
    end
    task next_sample;
        begin @(posedge valid); @(negedge clk); end
    endtask
    task record;
        input integer count;
        begin
            for (i = 0; i < count; i = i + 1) begin
                next_sample;
                $fdisplay(trace, "%0d,%0d,%0d,%0d,%0d",
                          instrument, segment, offset, left, active);
                offset = offset + 1;
            end
        end
    endtask
    task parameter_event;
        input [3:0] id;
        input [15:0] value;
        begin
            @(negedge clk); param_valid = 1; param_id = id; param_value = value;
            @(negedge clk); param_valid = 0;
            repeat (2) next_sample;
        end
    endtask
    task note_event;
        input [1:0] kind;
        input [6:0] note;
        begin
            @(negedge clk); event_valid = 1; event_type = kind; note_id = note;
            @(negedge clk); event_valid = 0;
        end
    endtask
    initial begin
        trace = $fopen("waveforms/guitar_audition.csv", "w");
        if (!trace) $fatal(1, "cannot open guitar capture");
        $fdisplay(trace, "instrument,segment,index,audio,active");
        chord[0] = 48; chord[1] = 55; chord[2] = 60; chord[3] = 64;
        for (j = 0; j < 2; j = j + 1) begin
            instrument = j == 0 ? 0 : 3;
            @(negedge clk); rst_n = 0;
            repeat (4) @(negedge clk);
            rst_n = 1;
            repeat (80) @(negedge clk);
            parameter_event(`PARAM_INSTRUMENT, instrument);
            parameter_event(`PARAM_VOLUME, 16'h3fff);
            repeat (520) next_sample;
            if (!ready || dut.instrument !== instrument || dut.volume !== 16'h3fff)
                $fatal(1, "guitar instrument selection");
            segment = 0; offset = 0;
            note_event(`EVENT_NOTE_ON, 69);
            record(36000);
            if (dut.a2.voice_instrument[1:0] !== instrument)
                $fatal(1, "voice did not latch requested instrument");
            note_event(`EVENT_NOTE_OFF, 69);
            record(7200);
            if (active !== 0 || left !== 0) $fatal(1, "solo release");
            segment = 1; offset = 0;
            for (slot = 0; slot < 4; slot = slot + 1) begin
                note_event(`EVENT_NOTE_ON, chord[slot]);
                record(6000);
                if (active !== slot + 1) $fatal(1, "arpeggio voice count");
            end
            record(7200);
            if (active !== 4) $fatal(1, "arpeggio lost voice");
            for (slot = 0; slot < 4; slot = slot + 1)
                note_event(`EVENT_NOTE_OFF, chord[slot]);
            released = 0; completed = 0;
            for (slot = 0; slot < 4; slot = slot + 1) release_ticks[slot] = 0;
            for (i = 0; i < 7200; i = i + 1) begin
                next_sample;
                for (slot = 0; slot < 4; slot = slot + 1) begin
                    if (dut.a2.envelope_stages[slot*3 +: 3] == 4) begin
                        released[slot] = 1;
                        release_ticks[slot] = release_ticks[slot] + 1;
                    end else if (released[slot] && !completed[slot]) begin
                        if (release_ticks[slot] != 4800 ||
                            dut.a2.envelope_levels[slot*16 +: 16] !== 0)
                            $fatal(1, "guitar default release duration");
                        completed[slot] = 1;
                    end
                end
                $fdisplay(trace, "%0d,%0d,%0d,%0d,%0d",
                          instrument, segment, offset, left, active);
                offset = offset + 1;
            end
            if (completed !== 4'hf || active !== 0 || left !== 0)
                $fatal(1, "arpeggio release/silence");
            $display("[PASS] instrument %0d: A4 + four-note arpeggio + default release", instrument);
            $fflush(trace);
        end
        $fclose(trace);
        $display("GUITAR AUDITION PASS");
        $finish;
    end
    initial begin #1_600_000_000; $fatal(1, "guitar timeout"); end
endmodule

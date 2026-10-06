`timescale 1ns/1ps
`include "event_defs.vh"

module tb_audio_core_a3_audition;
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
    integer trace, timbre, i, index = 0;
    integer initial_level, expected_level, prior_level;
    reg signed [23:0] held_sample;
    reg seen_valid = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            divider <= 0; sample_tick <= 0;
        end else begin
            divider <= divider == 255 ? 0 : divider + 1;
            sample_tick <= divider == 255;
        end
    end
    // Only slot count differs. Oscillator, envelope and mixer are production RTL.
    // The separate long test verifies the default 32-slot configuration.
    audio_core #(.VOICE_COUNT(1)) dut (
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
        if (!rst_n) begin
            last_valid = 0; seen_valid = 0;
        end else if (valid) begin
            if (cycle - tick_cycle != 75 ||
                (last_valid != 0 && cycle - last_valid != 256))
                $fatal(1, "audition sample cadence mismatch");
            if ((^left) === 1'bx || left !== right || overload ||
                event_overflow || param_overflow)
                $fatal(1, "audition unknown/clipped PCM or queue overflow");
            last_valid = cycle; held_sample = left; seen_valid = 1;
        end else if (seen_valid && left !== held_sample)
            $fatal(1, "audition output changed between valid pulses");
    end

    task next_sample;
        begin @(posedge valid); @(negedge clk); end
    endtask
    task record_sample;
        input integer offset;
        begin
            $fdisplay(trace, "timbre%0d,%0d,%0d", timbre, offset, left);
            index = index + 1;
        end
    endtask
    task send_param;
        input [3:0] id;
        input [15:0] value;
        begin
            @(negedge clk);
            param_valid = 1; param_id = id; param_value = value;
            @(negedge clk); param_valid = 0;
            repeat (2) next_sample;
        end
    endtask
    task send_event;
        input [1:0] kind;
        begin
            @(negedge clk); event_valid = 1; event_type = kind;
            @(negedge clk); event_valid = 0;
        end
    endtask
    task play_note;
        begin
            note_id = 69;
            send_event(`EVENT_NOTE_ON);
            // Preserve attack and decay in the listening capture.
            for (i = 0; i < 24000; i = i + 1) begin
                next_sample;
                record_sample(i);
            end
            send_event(`EVENT_NOTE_OFF);
            next_sample;
            if (dut.a2.envelope_stages !== 3'd4)
                $fatal(1, "audition missing release entry");
            initial_level = dut.a2.envelope_levels;
            if (initial_level <= 0) $fatal(1, "release started at zero");
            prior_level = initial_level;
            for (i = 0; i < 4800; i = i + 1) begin
                if (i != 0) next_sample;
                expected_level = initial_level - (initial_level * i) / 4800;
                if (dut.a2.envelope_stages !== 3'd4 ||
                    dut.a2.envelope_levels !== expected_level ||
                    dut.a2.envelope_levels > prior_level || active !== 1)
                    $fatal(1, "audition release error timbre %0d at %0d", timbre, i);
                prior_level = dut.a2.envelope_levels;
                record_sample(24000 + i);
            end
            next_sample;
            if (active !== 0 || left !== 0 || dut.a2.envelope_levels !== 0)
                $fatal(1, "audition nonzero after 4800 release ticks");
            for (i = 0; i < 2400; i = i + 1) begin
                record_sample(28800 + i);
                next_sample;
                if (active !== 0 || left !== 0)
                    $fatal(1, "audition nonzero silent tail");
            end
            $display("[PASS] timbre %0d: 24000 held + 4800 release + 2400 silence", timbre);
            $fflush(trace);
        end
    endtask
    initial begin
        trace = $fopen("waveforms/a3_audition.csv", "w");
        if (!trace) $fatal(1, "cannot open audition capture");
        $fdisplay(trace, "scenario,sample,audio");
        for (timbre = 0; timbre < 3; timbre = timbre + 1) begin
            @(negedge clk); rst_n = 0;
            repeat (4) @(negedge clk);
            rst_n = 1;
            repeat (80) @(negedge clk);
            send_param(`PARAM_INSTRUMENT, timbre);
            send_param(`PARAM_VOLUME, 16'h7fff);
            repeat (520) next_sample;
            if (!ready || dut.volume !== 16'h7fff) $fatal(1, "audition setup failed");
            index = 0;
            play_note();
        end
        $fclose(trace);
        $display("A3 AUDITION PASS: three timbres, full A4 captures, default envelopes");
        $finish;
    end
    initial begin
        #1_000_000_000;
        $fatal(1, "audition timeout");
    end
endmodule

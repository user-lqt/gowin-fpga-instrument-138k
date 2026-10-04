`timescale 1ns/1ps
`include "event_defs.vh"

module tb_audio_core_piano_melody;
    localparam integer NOTE_SAMPLES = 34286;
`ifdef GUITAR_MELODY
    localparam integer MELODY_INSTRUMENT = 3;
`elsif FLUTE_MELODY
    localparam integer MELODY_INSTRUMENT = 2;
`else
    localparam integer MELODY_INSTRUMENT = 0;
`endif
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, sample_tick = 0, event_valid = 0, param_valid = 0;
    reg [1:0] event_type = 0;
    reg [6:0] note_id = 60;
    reg [7:0] velocity = 105;
    reg [3:0] param_id = 0;
    reg [15:0] param_value = 0;
    wire valid, ready, overload, event_overflow, param_overflow;
    wire signed [23:0] left, right;
    wire [5:0] active;
    integer divider = 0, cycle = 0, tick_cycle = 0, last_valid = 0;
    integer trace, i, n;
    integer melody [0:13];
    reg signed [23:0] held_sample;
    reg seen_valid = 0;

    always @(posedge clk) begin
        if (!rst_n) begin divider <= 0; sample_tick <= 0; end
        else begin
            divider <= divider == 63 ? 0 : divider + 1;
            sample_tick <= divider == 63;
        end
    end

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
        if (!rst_n) begin last_valid = 0; seen_valid = 0; end
        else if (valid) begin
            if (cycle - tick_cycle != 19 ||
                (last_valid != 0 && cycle - last_valid != 64))
                $fatal(1, "melody sample cadence mismatch");
            if ((^left) === 1'bx || left !== right || overload ||
                event_overflow || param_overflow)
                $fatal(1, "melody PCM or queue fault");
`ifdef FLUTE_MELODY
            if (active && (dut.a2.voices[0].u_voice.u_oscillator.timbres.result >= 32767 ||
                           dut.a2.voices[0].u_voice.u_oscillator.timbres.result <= -32768))
                $fatal(1, "qudi oscillator clipping");
`endif
`ifdef PIANO_REFERENCE
            if (dut.a2.voices[0].u_voice.u_oscillator.timbres.result >= 32767 ||
                dut.a2.voices[0].u_voice.u_oscillator.timbres.result <= -32768)
                $fatal(1, "piano oscillator clipping: raw=%0d result=%0d h1=%0d upper=%0d bright=%0d",
                    dut.a2.voices[0].u_voice.u_oscillator.timbres.piano_result,
                    dut.a2.voices[0].u_voice.u_oscillator.timbres.result,
                    dut.a2.voices[0].u_voice.u_oscillator.timbres.piano_h1,
                    dut.a2.voices[0].u_voice.u_oscillator.timbres.piano_upper,
                    dut.a2.voices[0].u_voice.u_oscillator.timbres.piano_bright);
`endif
            last_valid = cycle;
            held_sample = left;
            seen_valid = 1;
        end else if (seen_valid && left !== held_sample)
            $fatal(1, "melody output hold");
    end

    task next_sample;
        begin @(posedge valid); @(negedge clk); end
    endtask
    task send_param;
        input [3:0] id;
        input [15:0] value;
        begin
            @(negedge clk); param_valid = 1; param_id = id; param_value = value;
            @(negedge clk); param_valid = 0;
            repeat (2) next_sample;
        end
    endtask
    task send_event;
        input [1:0] kind;
        input [6:0] note;
        begin
            @(negedge clk); event_valid = 1; event_type = kind; note_id = note;
            @(negedge clk); event_valid = 0;
        end
    endtask
    task record;
        input integer count;
        begin
            for (i = 0; i < count; i = i + 1) begin
                next_sample;
                $fdisplay(trace, "%0d,%0d", n, left);
            end
        end
    endtask

    initial begin
`ifdef GUITAR_MELODY
        trace = $fopen("waveforms/guitar_twinkle.csv", "w");
`elsif FLUTE_MELODY
        trace = $fopen("waveforms/flute_twinkle.csv", "w");
`elsif PIANO_REFERENCE
        trace = $fopen("waveforms/piano_upright_twinkle.csv", "w");
`else
        trace = $fopen("waveforms/piano_twinkle.csv", "w");
`endif
        if (!trace) $fatal(1, "cannot open melody capture");
        $fdisplay(trace, "note_index,audio");
        melody[0] = 60; melody[1] = 60; melody[2] = 67; melody[3] = 67;
        melody[4] = 69; melody[5] = 69; melody[6] = 67;
        melody[7] = 65; melody[8] = 65; melody[9] = 64; melody[10] = 64;
        melody[11] = 62; melody[12] = 62; melody[13] = 60;
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (80) @(negedge clk);
        send_param(`PARAM_INSTRUMENT, MELODY_INSTRUMENT);
        send_param(`PARAM_VOLUME, 16'h7fff);
        repeat (520) next_sample;
        if (!ready || dut.instrument !== MELODY_INSTRUMENT || dut.volume !== 16'h7fff)
            $fatal(1, "melody setup failed");
`ifdef PIANO_REFERENCE
        $fclose(trace);
        trace = $fopen("waveforms/piano_upright_register.csv", "w");
        if (!trace) $fatal(1, "cannot open piano register capture");
        $fdisplay(trace, "note_index,audio");
        for (n = 0; n < 6; n = n + 1) begin
            velocity = n % 2 == 0 ? 45 : 110;
            note_id = 60 + (n / 2) * 9;
            send_event(`EVENT_NOTE_ON, note_id);
            record(18000);
            send_event(`EVENT_NOTE_OFF, note_id);
            record(7200);
            if (active !== 0 || left !== 0) $fatal(1, "piano register release");
        end
        $fclose(trace);
        trace = $fopen("waveforms/piano_upright_twinkle.csv", "w");
        if (!trace) $fatal(1, "cannot reopen piano melody capture");
        $fdisplay(trace, "note_index,audio");
        velocity = 105;
`endif
`ifdef FLUTE_MELODY
        $fclose(trace);
        trace = $fopen("waveforms/qudi_register.csv", "w");
        if (!trace) $fatal(1, "cannot open register capture");
        $fdisplay(trace, "note_index,audio");
        for (n = 0; n < 7; n = n + 1) begin
            case (n)
                0: note_id = 69;
                1: note_id = 71;
                2: note_id = 73;
                3: note_id = 74;
                4: note_id = 76;
                5: note_id = 78;
                6: note_id = 79;
            endcase
            send_event(`EVENT_NOTE_ON, note_id);
            record(18000);
            send_event(`EVENT_NOTE_OFF, note_id);
            record(7200);
            if (active !== 0 || left !== 0) $fatal(1, "register release");
        end
        $fclose(trace);
        trace = $fopen("waveforms/flute_twinkle.csv", "w");
        if (!trace) $fatal(1, "cannot reopen melody capture");
        $fdisplay(trace, "note_index,audio");
        for (n = 0; n < 14; n = n + 1) melody[n] = melody[n] + 9;
`endif
        for (n = 0; n < 14; n = n + 1) begin
            send_event(`EVENT_NOTE_ON, melody[n]);
`ifdef FLUTE_MELODY
            record(NOTE_SAMPLES - 4800);
            send_event(`EVENT_NOTE_OFF, melody[n]);
            record(4800);
`else
            record(NOTE_SAMPLES);
            send_event(`EVENT_NOTE_OFF, melody[n]);
            repeat (20) next_sample;
`endif
        end
`ifdef PIANO_REFERENCE
        n = 14;
        record(5000);
`else
        repeat (5000) next_sample;
`endif
        if (active !== 0 || left !== 0) $fatal(1, "melody release did not reach silence");
        $fclose(trace);
        $display("MELODY PASS: 14-note melody, selected timbre, release to silence");
        $finish;
    end
    initial begin #500_000_000; $fatal(1, "melody timeout"); end
endmodule

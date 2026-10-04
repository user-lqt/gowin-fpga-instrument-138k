`timescale 1ns/1ps

module tb_voice;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b1;
    reg sample_tick = 1'b0;
    reg note_on = 1'b0;
    reg note_off = 1'b0;
    reg [6:0] note_id;
    reg [7:0] velocity = 8'd127;

    wire signed [23:0] audio;
    wire active;
    wire [15:0] envelope_level;
    wire [2:0] envelope_stage;

    integer checks = 0;
    integer failures = 0;
    integer i;
    integer peak_attack = 0;
    integer peak_sustain = 0;
    reg saw_nonzero = 1'b0;
    reg [31:0] phase_before;
    reg [15:0] level_before;

    voice #(
        .ATTACK_SAMPLES(4),
        .DECAY_SAMPLES(4),
        .SUSTAIN_LEVEL(16'd32768),
        .RELEASE_SAMPLES(5)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .sample_tick(sample_tick),
        .note_on(note_on),
        .note_off(note_off),
        .note_id(note_id),
        .velocity(velocity),
        .instrument(2'd0),
        .audio(audio),
        .active(active),
        .envelope_level(envelope_level),
        .envelope_stage(envelope_stage)
    );

`define CHECK(condition, label)           \
    begin                                   \
        checks = checks + 1;                \
        if (!(condition)) begin             \
            failures = failures + 1;        \
            $display("[FAIL] %s", label);  \
        end else                            \
            $display("[PASS] %s", label);  \
    end

    task tick;
        begin
            repeat (256) @(negedge clk);
            sample_tick = 1'b1;
            @(negedge clk);
            sample_tick = 1'b0;
        end
    endtask

    task trigger_on;
        begin
            @(negedge clk);
            note_on = 1'b1;
            @(negedge clk);
            note_on = 1'b0;
        end
    endtask

    task trigger_off;
        begin
            @(negedge clk);
            note_off = 1'b1;
            @(negedge clk);
            note_off = 1'b0;
        end
    endtask

    function integer absolute_audio;
        input signed [23:0] sample;
        begin
            if (sample < 0)
                absolute_audio = -sample;
            else
                absolute_audio = sample;
        end
    endfunction

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b0;
        #1;
        `CHECK(audio === 24'sd0 && !active && envelope_level == 0,
               "reset mutes voice");
        rst_n = 1'b1;
        note_id = 7'd69;
        repeat (3) @(negedge clk);
        `CHECK(audio === 24'sd0, "idle voice stays silent");

        trigger_on();
        `CHECK(active && envelope_stage == 3'd1, "note on starts attack");
        for (i = 0; i < 4; i = i + 1) tick();
        `CHECK(envelope_level == 16'hffff && envelope_stage == 3'd2,
               "attack reaches peak");
        repeat (120) begin
            tick();
            @(negedge clk);
            if ((^audio) !== 1'bx) begin
                if (absolute_audio(audio) > peak_attack)
                    peak_attack = absolute_audio(audio);
                if (audio !== 24'sd0)
                    saw_nonzero = 1'b1;
            end
        end
        `CHECK(saw_nonzero, "oscillator produces nonzero samples");
        `CHECK(peak_attack <= 8388607, "voice peak is within signed 24 bit");

        for (i = 0; i < 4; i = i + 1) tick();
        `CHECK(envelope_level == 16'd32768 && envelope_stage == 3'd3,
               "decay reaches sustain");
        repeat (120) begin
            tick();
            @(negedge clk);
            if ((^audio) !== 1'bx && absolute_audio(audio) > peak_sustain)
                peak_sustain = absolute_audio(audio);
        end
        `CHECK(peak_sustain > 0 && peak_sustain <= peak_attack + 512,
               "sustain output stays within envelope target");
        phase_before = dut.u_oscillator.u_phase_acc.phase;
        level_before = envelope_level;
        trigger_on();
        `CHECK(dut.u_oscillator.u_phase_acc.phase == phase_before &&
               envelope_level == level_before,
               "held retrigger preserves phase and envelope");
        trigger_off();
        `CHECK(active && envelope_stage == 3'd4 && envelope_level != 0,
               "note off enters release without muting");
        tick();
        `CHECK(audio != 0 && active, "output continues during release");
        phase_before = dut.u_oscillator.u_phase_acc.phase;
        level_before = envelope_level;
        trigger_on();
        `CHECK(dut.u_oscillator.u_phase_acc.phase == phase_before &&
               envelope_level == level_before,
               "release retrigger preserves phase and envelope");
        trigger_off();
        for (i = 0; i < 5; i = i + 1) tick();
        `CHECK(!active && envelope_level == 0 && audio == 0,
               "release finishes at silence");
        rst_n = 1'b0;
        #1;
        `CHECK(audio === 24'sd0 && !active, "reset stays silent");

        if (failures == 0)
            $display("VOICE PASS (%0d/%0d)", checks, checks);
        else
            $fatal(1, "VOICE FAIL (%0d failed/%0d)", failures, checks);
        $finish;
    end
endmodule

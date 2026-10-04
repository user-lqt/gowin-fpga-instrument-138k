`timescale 1ns/1ps

module tb_adsr;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg sample_tick = 1'b0;
    reg note_on = 1'b0;
    reg note_off = 1'b0;
    wire [15:0] level;
    wire active;
    wire [2:0] stage;
    integer checks = 0;
    integer errors = 0;
    integer i;
    reg [15:0] prev_level;

    adsr #(
        .ATTACK_SAMPLES(4),
        .DECAY_SAMPLES(4),
        .SUSTAIN_LEVEL(16'd32768),
        .RELEASE_SAMPLES(5)
    ) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .note_on(note_on), .note_off(note_off),
        .level(level), .active(active), .stage(stage)
    );

`define CHECK(condition, label)            \
    begin                                    \
        checks = checks + 1;                 \
        if (!(condition)) begin              \
            errors = errors + 1;             \
            $display("[FAIL] %s", label);   \
        end else                             \
            $display("[PASS] %s", label);   \
    end

    task tick;
        begin
            @(negedge clk);
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

    initial begin
        repeat (3) @(negedge clk);
        `CHECK(level === 16'd0 && !active && stage == 3'd0, "reset silence");
        rst_n = 1'b1;
        trigger_on();
        `CHECK(active && stage == 3'd1 && level == 0, "note on enters attack");
        for (i = 0; i < 4; i = i + 1) begin
            prev_level = level;
            tick();
            `CHECK(level > prev_level, "attack increases on tick");
        end
        `CHECK(level == 16'hffff && stage == 3'd2, "attack reaches peak");
        for (i = 0; i < 4; i = i + 1) begin
            prev_level = level;
            tick();
            `CHECK(level < prev_level, "decay decreases on tick");
        end
        `CHECK(level == 16'd32768 && stage == 3'd3, "decay reaches sustain");
        repeat (5) @(negedge clk);
        `CHECK(level == 16'd32768, "level holds without tick");
        tick();
        `CHECK(level == 16'd32768, "sustain holds across tick");
        trigger_off();
        `CHECK(active && stage == 3'd4 && level == 16'd32768, "note off enters release without cut");
        prev_level = level;
        tick();
        `CHECK(level < prev_level && level != 0 && active, "release fades on tick");
        for (i = 0; i < 4; i = i + 1) tick();
        `CHECK(level == 0 && !active && stage == 3'd0, "release ends at zero");

        trigger_on();
        tick();
        trigger_off();
        `CHECK(active && stage == 3'd4 && level != 0, "early note off releases current level");
        prev_level = level;
        tick();
        `CHECK(active && level < prev_level && level != 0,
               "early release does not snap to zero");
        for (i = 0; i < 4; i = i + 1) tick();
        `CHECK(!active && level == 0,
               "early release uses the configured duration");
        trigger_on();
        tick();
        trigger_off();
        trigger_on();
        `CHECK(active && stage == 3'd1 && level != 0, "retrigger starts from current level");
        tick();
        rst_n = 1'b0;
        #1;
        `CHECK(level == 0 && !active, "asynchronous reset mutes active envelope");

        if (errors == 0) $display("ADSR PASS (%0d/%0d)", checks, checks);
        else $fatal(1, "ADSR FAIL (%0d/%0d)", errors, checks);
        $finish;
    end
endmodule

`timescale 1ns/1ps
`include "event_defs.vh"

module tb_voice_allocator;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg sample_tick = 1'b0;
    reg event_valid = 1'b0;
    reg [1:0] event_type = `EVENT_NONE;
    reg [6:0] note_id = 7'd0;
    reg [7:0] velocity = 8'd0;
    reg [3:0] voice_active = 4'd0;

    wire [3:0] voice_note_on;
    wire [3:0] voice_note_off;
    wire [3:0] key_down;
    wire [27:0] voice_note_id;
    wire [31:0] voice_velocity;
    wire full_pulse;

    integer checks = 0;
    integer failures = 0;

    voice_allocator #(.VOICES(4)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .sample_tick(sample_tick),
        .event_valid(event_valid),
        .event_type(event_type),
        .note_id(note_id),
        .velocity(velocity),
        .voice_active(voice_active),
        .voice_note_on(voice_note_on),
        .voice_note_off(voice_note_off),
        .key_down(key_down),
        .voice_note_id(voice_note_id),
        .voice_velocity(voice_velocity),
        .full_pulse(full_pulse)
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

    task send_event;
        input [1:0] kind;
        input [6:0] note;
        input [7:0] vel;
        begin
            @(negedge clk);
            event_valid = 1'b1;
            event_type = kind;
            note_id = note;
            velocity = vel;
        end
    endtask

    task tick;
        begin
            @(negedge clk);
            sample_tick = 1'b1;
            @(negedge clk);
            sample_tick = 1'b0;
            event_valid = 1'b0;
        end
    endtask

    initial begin
        repeat (2) @(negedge clk);
        `CHECK(voice_note_on == 0 && voice_note_off == 0 && key_down == 0,
               "reset clears all slots");
        rst_n = 1'b1;

        send_event(`EVENT_NOTE_ON, 7'd60, 8'd90);
        `CHECK(voice_note_on == 0 && key_down == 0,
               "event waits for sample tick");
        tick();
        `CHECK(voice_note_on == 4'b0001 && key_down == 4'b0001 &&
               voice_note_id[6:0] == 7'd60 && voice_velocity[7:0] == 8'd90,
               "first note takes first free slot");
        voice_active[0] = 1'b1;
        tick();
        `CHECK(voice_note_on == 0, "note on pulse is one clock wide");

        send_event(`EVENT_NOTE_ON, 7'd64, 8'd100);
        tick();
        `CHECK(voice_note_on == 4'b0010 && key_down == 4'b0011 &&
               voice_note_id[13:7] == 7'd64, "second note takes second slot");
        voice_active[1] = 1'b1;

        send_event(`EVENT_NOTE_ON, 7'd67, 8'd110);
        tick();
        voice_active[2] = 1'b1;
        send_event(`EVENT_NOTE_ON, 7'd72, 8'd120);
        tick();
        voice_active[3] = 1'b1;
        `CHECK(key_down == 4'b1111 && !full_pulse,
               "four independent notes fill four slots");

        send_event(`EVENT_NOTE_ON, 7'd76, 8'd110);
        tick();
        `CHECK(full_pulse && voice_note_on == 0 && key_down == 4'b1111,
               "full allocator reports overflow without stealing voice");
        tick();
        `CHECK(!full_pulse, "full pulse clears on next clock");

        send_event(`EVENT_NOTE_OFF, 7'd64, 8'd0);
        tick();
        `CHECK(voice_note_off == 4'b0010 && key_down == 4'b1101 &&
               voice_active[1], "note off releases matching slot but keeps it active");
        send_event(`EVENT_NOTE_ON, 7'd76, 8'd110);
        tick();
        `CHECK(full_pulse && voice_note_on == 0,
               "release slot is not reused until inactive");
        voice_active[1] = 1'b0;
        send_event(`EVENT_NOTE_ON, 7'd76, 8'd110);
        tick();
        `CHECK(voice_note_on == 4'b0010 && voice_note_id[13:7] == 7'd76,
               "finished release frees slot for next note");

        send_event(`EVENT_NOTE_ON, 7'd60, 8'd50);
        tick();
        `CHECK(voice_note_on == 4'b0001 && voice_velocity[7:0] == 8'd50 &&
               key_down == 4'b1111, "repeated note retriggers existing slot");

        send_event(`EVENT_NOTE_OFF, 7'd99, 8'd0);
        tick();
        `CHECK(voice_note_off == 0 && key_down == 4'b1111,
               "unknown note off has no effect");

        send_event(`EVENT_NOTE_ON, 7'd60, 8'd0);
        tick();
        `CHECK(voice_note_on == 0 && key_down == 4'b1111,
               "zero velocity does not retrigger");

        // The FIFO upstream dequeues one event per tick; no event is held
        // or replayed by this allocator after its pulse has passed.
        send_event(`EVENT_NOTE_OFF, 7'd60, 8'd0);
        tick();
        `CHECK(voice_note_off == 4'b0001 && !key_down[0],
               "first consecutive dequeue releases note");
        send_event(`EVENT_NOTE_ON, 7'd60, 8'd75);
        tick();
        `CHECK(voice_note_on == 0 && full_pulse && !key_down[0],
               "next dequeue cannot steal a releasing voice");
        voice_active[0] = 1'b0;
        send_event(`EVENT_NOTE_ON, 7'd60, 8'd75);
        tick();
        `CHECK(voice_note_on == 4'b0001 && key_down[0] &&
               voice_velocity[7:0] == 8'd75,
               "finished release can be reused");
        tick();
        `CHECK(voice_note_on == 0 && voice_note_off == 0,
               "consumed event never replays");

        rst_n = 1'b0;
        #1;
        `CHECK(key_down == 0 && voice_note_id == 0 && voice_velocity == 0,
               "reset clears slot metadata");

        if (failures == 0)
            $display("ALLOCATOR PASS (%0d/%0d)", checks, checks);
        else
            $fatal(1, "ALLOCATOR FAIL (%0d failed/%0d)", failures, checks);
        $finish;
    end
endmodule

`timescale 1ns/1ps
`include "event_defs.vh"
`include "status_defs.vh"

// C contract test using the real A audio_core and /256 sample scheduler.
module tb_audio_overflow_status;
    reg clk = 0;
    always #40.6901 clk = ~clk;
    reg rst_n = 0;
    reg event_valid = 0, param_valid = 0;
    reg [1:0] event_type = `EVENT_NONE;
    reg [6:0] note_id = 0;
    reg [7:0] velocity = 0;
    reg [3:0] param_id = `PARAM_VOLUME;
    reg [15:0] param_value = 0;
    wire sample_tick, bck, bck_en;
    wire audio_core_valid, engine_ready, overload_flag;
    wire signed [23:0] audio_left, audio_right;
    wire [5:0] active_voice_count;
    wire event_overflow, param_overflow;
    wire audio_locked, i2s_active, system_ready;
    wire [7:0] system_error;
    integer k;
    sample_scheduler #(.CLK_DIV_BCK(4), .CLK_DIV_SAMPLE(256)) scheduler (
        .clk_audio(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .bck(bck), .bck_en(bck_en)
    );
    audio_core core (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .event_valid(event_valid), .event_type(event_type),
        .note_id(note_id), .velocity(velocity),
        .param_valid(param_valid), .param_id(param_id),
        .param_value(param_value), .audio_core_valid(audio_core_valid),
        .audio_left(audio_left), .audio_right(audio_right),
        .active_voice_count(active_voice_count),
        .engine_ready(engine_ready), .overload_flag(overload_flag),
        .event_overflow(event_overflow), .param_overflow(param_overflow)
    );
    system_status status (
        .clk_audio(clk), .board_rst_n(rst_n), .audio_rst_n(rst_n),
        .pll_locked(1'b1), .sample_tick(sample_tick),
        .frame_start(sample_tick), .engine_ready(engine_ready),
        .event_overflow(event_overflow), .param_overflow(param_overflow),
        .audio_locked(audio_locked), .i2s_active(i2s_active),
        .system_ready(system_ready), .system_error(system_error)
    );
    initial begin
        repeat (5) @(negedge clk); rst_n = 1;
        wait (system_ready);
        @(negedge clk);
        event_valid = 1; event_type = `EVENT_NOTE_ON;
        note_id = 69; velocity = 127;
        @(negedge clk); event_valid = 0;
        wait (active_voice_count == 1);
        repeat (3) @(posedge sample_tick);
        if (audio_left == 0) $fatal(1, "precondition: active note silent");
        // Start immediately after a tick, so the next 17 inputs precede the next tick.
        @(negedge sample_tick);
        for (k = 0; k < 17; k = k + 1) begin
            @(negedge clk);
            event_valid = 1;
            event_type = (k == 16) ? `EVENT_NOTE_OFF : `EVENT_NOTE_ON;
            note_id = 69; velocity = (k == 16) ? 0 : 127;
        end
        @(negedge clk); event_valid = 0;
        #1;
        if (!event_overflow || system_ready || !(system_error & `ERR_INPUT_QUEUE_OVERFLOW))
            $fatal(1, "event overflow not reported through C");
        if (active_voice_count != 0 || core.ev_count != 0 || audio_left != 0 || audio_right != 0)
            $fatal(1, "event overflow did not mute and clear queue");
        repeat (3) @(posedge sample_tick);
        if (active_voice_count != 0 || audio_left != 0)
            $fatal(1, "fault mute did not persist");
        @(negedge clk); rst_n = 0;
        repeat (3) @(negedge clk);
        if (event_overflow || param_overflow || system_ready || system_error)
            $fatal(1, "reset did not clear fault");
        rst_n = 1;
        wait (system_ready);
        @(negedge sample_tick);
        for (k = 0; k < 5; k = k + 1) begin
            @(negedge clk);
            param_valid = 1; param_value = 1000 + k;
        end
        @(negedge clk); param_valid = 0;
        #1;
        if (!param_overflow || !system_ready || !(system_error & `ERR_INPUT_QUEUE_OVERFLOW))
            $fatal(1, "parameter overflow did not warn while keeping B enabled");
        repeat (5) @(posedge sample_tick);
        if (core.volume != 1003)
            $fatal(1, "accepted parameters not consumed in order: %0d", core.volume);
        $display("PASS A overflow -> C fault, mute, reset and parameter warning");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "A/C overflow status timeout");
    end
endmodule

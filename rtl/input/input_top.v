`timescale 1ns/1ps
// B0/B1/B2 subsystem, not the board/system top. Same clk as A/C control logic.
// C must synchronize rst_n deassertion and system_ready to clk.
// system_ready=0 resets B, tri-states rows, and suppresses events. On ready,
// default parameters are resent; reset the audio voices at the same time.
// Receivers must capture EVERY valid cycle, even before input_ready goes high.
// Independent note and parameter channels may be valid on the same clock.
// Physical row tri-states must reach package IO without internal logic gates.
module input_top #(
    parameter integer CLK_HZ = 50000000,
    parameter integer ROW_CYCLES = CLK_HZ / 10000,
    parameter integer DEBOUNCE_FRAMES = 5,
    parameter integer FILTER_CYCLES = CLK_HZ / 20000,
    parameter integer BUTTON_CYCLES = CLK_HZ / 50,
    parameter integer BASE_NOTE = 60,
    parameter integer INSTRUMENT_COUNT = 1,
    parameter integer REVERSE_DIR = 0
) (
    input wire clk, rst_n, system_ready,
    input wire [3:0] col_in,
    output wire [3:0] row_out,
    input wire enc_a, enc_b, enc_sw_n,
    input wire [5:0] active_voice_count,
    input wire audio_locked, i2s_active, system_error,
    output wire event_valid,
    output wire [1:0] event_type,
    output wire [6:0] note_id,
    output wire [7:0] velocity,
    output wire param_valid,
    output wire [3:0] param_id,
    output wire [15:0] param_value,
    output wire [15:0] key_state, sensor_value,
    output wire input_ready,
    output wire [3:0] ui_page,
    output wire [15:0] ui_param_value,
    output wire ui_dirty,
    output wire [15:0] volume_value, instrument_value
);
    wire run_reset_n = rst_n & system_ready;
    wire keyboard_ready, encoder_ready;
    // B3 sensor hardware is intentionally absent in this baseline.
    assign sensor_value = 16'd0;
    assign input_ready = run_reset_n & keyboard_ready & encoder_ready;
    keyboard_input #(.ROW_CYCLES(ROW_CYCLES), .DEBOUNCE_FRAMES(DEBOUNCE_FRAMES),
        .BASE_NOTE(BASE_NOTE)) keys (
        .clk(clk), .rst_n(run_reset_n), .col_in(col_in), .row_out(row_out),
        .key_state(key_state), .input_ready(keyboard_ready),
        .event_valid(event_valid), .event_type(event_type), .note_id(note_id), .velocity(velocity)
    );
    encoder_control #(.FILTER_CYCLES(FILTER_CYCLES), .BUTTON_CYCLES(BUTTON_CYCLES),
        .REVERSE_DIR(REVERSE_DIR), .INSTRUMENT_COUNT(INSTRUMENT_COUNT)) controls (
        .clk(clk), .rst_n(run_reset_n), .enc_a(enc_a), .enc_b(enc_b), .enc_sw_n(enc_sw_n),
        .input_ready(encoder_ready), .volume_value(volume_value), .instrument_value(instrument_value),
        .param_valid(param_valid), .param_id(param_id), .param_value(param_value),
        .ui_page(ui_page), .ui_param_value(ui_param_value), .ui_dirty()
    );
    ui_state display_updates (
        .clk(clk), .rst_n(rst_n), .ui_page(ui_page), .volume_value(volume_value),
        .instrument_value(instrument_value), .active_voice_count(active_voice_count),
        .input_ready(input_ready), .audio_locked(audio_locked), .i2s_active(i2s_active),
        .system_error(system_error), .ui_dirty(ui_dirty)
    );
endmodule

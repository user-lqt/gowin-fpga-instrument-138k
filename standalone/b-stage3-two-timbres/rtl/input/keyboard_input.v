`timescale 1ns/1ps
// B1 keyboard-only integration top. All modules share clk and rst_n.
// System reset must reset the receiver/audio engine too, to clear held notes.
module keyboard_input #(
    parameter integer ROW_CYCLES = 5000,
    parameter integer DEBOUNCE_FRAMES = 5,
    parameter integer RELEASE_FRAMES = DEBOUNCE_FRAMES,
    parameter integer BASE_NOTE = 60
) (
    input wire clk,
    input wire rst_n,
    input wire [3:0] col_in,
    output wire [3:0] row_out,
    output wire [15:0] key_state,
    output wire input_ready,
    output wire event_valid,
    output wire [1:0] event_type,
    output wire [6:0] note_id,
    output wire [7:0] velocity
);
    matrix_keyboard #(.ROW_CYCLES(ROW_CYCLES),
        .DEBOUNCE_FRAMES(DEBOUNCE_FRAMES), .RELEASE_FRAMES(RELEASE_FRAMES)) keyboard (
        .clk(clk), .rst_n(rst_n), .col_in(col_in), .row_out(row_out),
        .key_state(key_state), .key_press(), .key_release(),
        .input_ready(input_ready)
    );
    key_map #(.BASE_NOTE(BASE_NOTE)) mapper (
        .clk(clk), .rst_n(rst_n), .key_state(key_state),
        .event_valid(event_valid), .event_type(event_type),
        .note_id(note_id), .velocity(velocity)
    );
endmodule

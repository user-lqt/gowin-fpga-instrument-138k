`timescale 1ns/1ps
`include "input_defs.vh"
// Full 24-key, 8x6, dual-contact keyboard input path.
module keyboard_24_input #(
    parameter integer ROW_CYCLES = 5000,
    parameter integer DEBOUNCE_FRAMES = 2,
    parameter integer RELEASE_DEBOUNCE_FRAMES = 2,
    parameter integer AB_MAX_FRAMES = 40,
    parameter integer BASE_NOTE = 48,
    parameter integer EVENT_INTERVAL_CYCLES = 256
) (
    input wire clk,
    input wire rst_n,
    input wire [5:0] col_in,
    output wire [7:0] row_out,
    output wire [23:0] key_state,
    output reg input_ready,
    output wire event_valid,
    output wire [1:0] event_type,
    output wire [6:0] note_id,
    output wire [7:0] velocity
);
    wire [47:0] contact_raw;
    wire scan_valid;
    wire [4:0] key_index;
    wire [7:0] key_velocity;

    matrix_scan_8x6 #(.ROW_CYCLES(ROW_CYCLES)) scanner (
        .clk(clk), .rst_n(rst_n), .col_in(col_in), .row_out(row_out),
        .contact_raw(contact_raw), .scan_valid(scan_valid)
    );
    keyboard_24_dual #(.DEBOUNCE_FRAMES(DEBOUNCE_FRAMES),
        .RELEASE_DEBOUNCE_FRAMES(RELEASE_DEBOUNCE_FRAMES),
        .AB_MAX_FRAMES(AB_MAX_FRAMES), .EVENT_INTERVAL_CYCLES(EVENT_INTERVAL_CYCLES)) decoder (
        .clk(clk), .rst_n(rst_n), .scan_valid(scan_valid),
        .contact_raw(contact_raw), .event_valid(event_valid),
        .event_type(event_type), .key_id(key_index),
        .velocity(key_velocity), .key_state(key_state)
    );
    assign note_id = BASE_NOTE + key_index;
    assign velocity = key_velocity;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) input_ready <= 0;
        else if (scan_valid) input_ready <= 1;
    end
endmodule

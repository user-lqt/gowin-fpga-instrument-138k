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
    output wire [7:0] velocity,
    output wire [31:0] strike_debug
);
    wire [47:0] contact_raw;
    wire scan_valid;
    wire [4:0] key_index;
    wire [7:0] key_velocity;
    wire [15:0] measured_frames;
    wire [4:0] measured_key;
    wire measured_valid;
    wire [15:0] measured_ms = (measured_frames * 32'd200) / 1000;
    // Same K1..K24 A->B boundaries as keyboard_24_dual, in scan frames.
    function integer key_threshold;
        input integer key;
        begin
            case (key)
                0: key_threshold=50;   1: key_threshold=90;
                2: key_threshold=30;   3: key_threshold=25;
                4: key_threshold=100;  5: key_threshold=100;
                6: key_threshold=100;  7: key_threshold=100;
                8: key_threshold=5;    9: key_threshold=50;
                10: key_threshold=15;  11: key_threshold=5;
                12: key_threshold=5;   13: key_threshold=150;
                14: key_threshold=100; 15: key_threshold=100;
                16: key_threshold=50;  17: key_threshold=5;
                18: key_threshold=50;  19: key_threshold=15;
                20: key_threshold=90;  21: key_threshold=5;
                22: key_threshold=150; 23: key_threshold=150;
                default: key_threshold=5;
            endcase
        end
    endfunction
    wire [7:0] measured_velocity = measured_frames < key_threshold(measured_key) ? 127 : 16;
    wire [5:0] a_index = (measured_key/6)*12 + measured_key%6;
    // Valid, live A/B states for last measured key, key index, velocity, ms.
    assign strike_debug = {measured_valid,contact_raw[a_index],contact_raw[a_index+6],
                           measured_key,measured_velocity,measured_ms};

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
        .velocity(key_velocity), .key_state(key_state),
        .measured_frames(measured_frames), .measured_key(measured_key), .measured_valid(measured_valid)
    );
    assign note_id = BASE_NOTE + key_index;
    assign velocity = key_velocity;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) input_ready <= 0;
        else if (scan_valid) input_ready <= 1;
    end
endmodule

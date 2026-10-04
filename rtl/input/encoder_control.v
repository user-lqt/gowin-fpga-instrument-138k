`timescale 1ns/1ps
// B-side local integration top. Not the system top and no physical pin assignments.
// enc_sw_n: external pullup, switch to GND, pressed=0 (D/E contacts).
// 1,000,000 clocks = 20 ms at 50 MHz; set for the actual clock frequency.
// A held button emits one press, including a button held through reset.
// Default four instrument IDs are placeholders, not four implemented sounds.
module encoder_control #(
    parameter integer FILTER_CYCLES = 2500,
    parameter integer BUTTON_CYCLES = 1000000,
    parameter integer REVERSE_DIR = 0,
    parameter integer INSTRUMENT_COUNT = 4
) (
    input wire clk, rst_n,
    input wire enc_a, enc_b, enc_sw_n,
    output wire input_ready,
    output wire [15:0] volume_value, instrument_value,
    output wire param_valid,
    output wire [3:0] param_id,
    output wire [15:0] param_value,
    output wire [3:0] ui_page,
    output wire [15:0] ui_param_value,
    output wire ui_dirty,
    output wire diagnostic_step_up, diagnostic_step_down
);
    wire step_up, step_down, press;
    assign diagnostic_step_up = step_up;
    assign diagnostic_step_down = step_down;
    encoder #(.FILTER_CYCLES(FILTER_CYCLES), .REVERSE_DIR(REVERSE_DIR)) rotation (
        .clk(clk), .rst_n(rst_n), .enc_a(enc_a), .enc_b(enc_b),
        .step_up(step_up), .step_down(step_down), .input_ready(input_ready)
    );
    key_debounce #(.DEBOUNCE_CYCLES(BUTTON_CYCLES)) button (
        .clk(clk), .rst_n(rst_n), .key_raw(~enc_sw_n),
        .key_stable(), .key_press(press), .key_release()
    );
    parameter_manager #(.ENABLE_INSTRUMENT(1), .INSTRUMENT_COUNT(INSTRUMENT_COUNT)) parameters (
        .clk(clk), .rst_n(rst_n), .step_up(step_up), .step_down(step_down),
        .select_press(press), .volume_value(volume_value), .instrument_value(instrument_value),
        .param_valid(param_valid), .param_id(param_id), .param_value(param_value),
        .ui_page(ui_page), .ui_param_value(ui_param_value), .ui_dirty(ui_dirty)
    );
endmodule

`timescale 1ns/1ps
// Local B-side integration/test top only; no board pins or system clocks assigned.
// enc_a/b are raw EC11 contacts. Push switch is not connected in this stage.
module encoder_volume #(
    parameter integer FILTER_CYCLES = 2500,
    parameter integer REVERSE_DIR = 0
) (
    input wire clk,
    input wire rst_n,
    input wire enc_a,
    input wire enc_b,
    output wire input_ready,
    output wire [15:0] volume_value,
    output wire param_valid,
    output wire [3:0] param_id,
    output wire [15:0] param_value,
    output wire [15:0] ui_param_value,
    output wire ui_dirty
);
    wire step_up, step_down;
    encoder #(.FILTER_CYCLES(FILTER_CYCLES), .REVERSE_DIR(REVERSE_DIR)) rotation (
        .clk(clk), .rst_n(rst_n), .enc_a(enc_a), .enc_b(enc_b),
        .step_up(step_up), .step_down(step_down), .input_ready(input_ready)
    );
    parameter_manager parameters (
        .select_press(1'b0), .instrument_value(), .ui_page(),
        .clk(clk), .rst_n(rst_n), .step_up(step_up), .step_down(step_down),
        .volume_value(volume_value), .param_valid(param_valid),
        .param_id(param_id), .param_value(param_value),
        .ui_param_value(ui_param_value), .ui_dirty(ui_dirty)
    );
endmodule

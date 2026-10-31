`timescale 1ns/1ps
// EC11_B physical input front end. Interpretation belongs to its controller.
// 245760 clocks is ~20 ms at the actual ~12.288 MHz audio clock.
module encoder_b_input #(
    parameter integer FILTER_CYCLES=2500,
    parameter integer BUTTON_CYCLES=245760,
    parameter integer REVERSE_DIR=0
) (
    input wire clk, rst_n,
    input wire enc_a, enc_b, enc_sw_n,
    output wire step_up, step_down, press, input_ready
);
    encoder #(.FILTER_CYCLES(FILTER_CYCLES), .REVERSE_DIR(REVERSE_DIR)) rotation (
        .clk(clk), .rst_n(rst_n), .enc_a(enc_a), .enc_b(enc_b),
        .step_up(step_up), .step_down(step_down), .input_ready(input_ready)
    );
    key_debounce #(.DEBOUNCE_CYCLES(BUTTON_CYCLES)) button (
        .clk(clk), .rst_n(rst_n), .key_raw(~enc_sw_n),
        .key_stable(), .key_press(press), .key_release()
    );
endmodule

`timescale 1ns/1ps
// Mode-0 behavioural ADC. Decode the actual MOSI command, then return CH data.
module mcp3008_model (
    input wire cs_n, sclk, mosi,
    input wire [9:0] ch0, ch1, ch2,
    output reg miso = 1
);
    integer rises = 0;
    reg [4:0] command = 0;
    reg [9:0] conversion = 0;
    always @(negedge cs_n) begin
        rises = 0;
        command = 0;
        miso = 1;
    end
    always @(posedge sclk) if (!cs_n) begin
        rises = rises + 1;
        if (rises <= 5) command = {command[3:0], mosi};
        if (rises == 5) begin
            if (command[4:3] !== 2'b11) $fatal(1, "ADC command not single-ended");
            case (command[2:0])
                0: conversion = ch0;
                1: conversion = ch1;
                2: conversion = ch2;
                default: $fatal(1, "unexpected ADC channel");
            endcase
        end
    end
    always @(negedge sclk or posedge cs_n) begin
        // Pull-up represents DOUT high impedance before the null response.
        if (cs_n || rises < 6) miso = 1;
        else if (rises == 6) miso = 0;
        else if (rises >= 7 && rises <= 16) miso = conversion[16-rises];
        else miso = 0;
    end
endmodule

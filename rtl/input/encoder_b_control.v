`timescale 1ns/1ps
`include "event_defs.vh"
// B4 menu: 0=glide time, 1=effect wet/dry mix. Audio semantics are A-owned.
// Both values use 0..127 UI units, mapped to the public 0..65535 payload.
module encoder_b_control #(
    parameter integer FILTER_CYCLES=2500,
    parameter integer BUTTON_CYCLES=245760
) (
    input wire clk,rst_n,enc_a,enc_b,enc_sw_n,
    output wire input_ready,
    output reg menu,
    output reg [6:0] glide_value,effect_value,
    output reg param_valid,
    output reg [3:0] param_id,
    output reg [15:0] param_value
);
    wire up,down,press;
    reg [1:0] startup;
    wire [6:0] current_value=menu ? effect_value : glide_value;
    reg [6:0] next_value;
    function [15:0] payload;
        input [6:0] value;
        reg [31:0] scaled;
        begin scaled=value*32'd65535+32'd63; payload=scaled/127; end
    endfunction
    encoder_b_input #(.FILTER_CYCLES(FILTER_CYCLES),.BUTTON_CYCLES(BUTTON_CYCLES)) inputs (
        .clk(clk),.rst_n(rst_n),.enc_a(enc_a),.enc_b(enc_b),.enc_sw_n(enc_sw_n),
        .step_up(up),.step_down(down),.press(press),.input_ready(input_ready)
    );
    always @* begin
        next_value=current_value;
        if(up && !down) next_value=current_value>=123 ? 7'd127 : current_value+7'd4;
        if(down && !up) next_value=current_value<4 ? 7'd0 : current_value-7'd4;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            menu<=0;glide_value<=0;effect_value<=0;startup<=0;
            param_valid<=0;param_id<=`PARAM_GLIDE;param_value<=0;
        end else begin
            param_valid<=0;
            if(startup<2) begin
                param_valid<=1;param_value<=0;
                param_id<=startup==0 ? `PARAM_GLIDE : `PARAM_EFFECT_MIX;
                startup<=startup+1'b1;
            end else begin
                // A simultaneous press/rotation edits the currently displayed
                // menu before switching, so neither user action disappears.
                if(press) menu<=~menu;
                if(next_value!=current_value) begin
                    if(menu) effect_value<=next_value;else glide_value<=next_value;
                    param_valid<=1;
                    param_id<=menu ? `PARAM_EFFECT_MIX : `PARAM_GLIDE;
                    param_value<=payload(next_value);
                end
            end
        end
    end
endmodule

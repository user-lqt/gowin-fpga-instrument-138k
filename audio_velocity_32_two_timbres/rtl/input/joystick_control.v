`timescale 1ns/1ps
`include "event_defs.vh"
// Converts MCP3008 joystick samples to calibrated pitch bend and modulation.
// Outputs are public parameter payloads; audio_core must consume these IDs.
module joystick_control #(
    parameter [9:0] CENTER_X=10'd512,
    parameter [9:0] CENTER_Y=10'd512,
    parameter [9:0] DEADZONE=10'd32,
    parameter integer MAX_BEND=8192
) (
    input wire clk,rst_n,
    input wire sample_valid,
    input wire [2:0] sample_channel,
    input wire [9:0] ch1_x,ch2_y,
    output reg param_valid,
    output reg [3:0] param_id,
    output reg [15:0] param_value,
    output reg signed [15:0] pitch_bend,
    output reg [15:0] modulation,
    output reg [9:0] filtered_x,filtered_y
);
    reg [12:0] x_acc,y_acc;
    reg [2:0] x_count,y_count;
    reg signed [11:0] dx,dy;
    reg signed [23:0] bend_calc;
    reg [15:0] mod_calc;
    reg [11:0] abs_dy;
    function [9:0] deadzone_value;
        input [9:0] raw,center;
        reg signed [11:0] diff;
        begin
            diff=$signed({1'b0,raw})-$signed({1'b0,center});
            if(diff > -$signed({2'b0,DEADZONE}) && diff < $signed({2'b0,DEADZONE}))
                deadzone_value=center;
            else deadzone_value=raw;
        end
    endfunction
    always @* begin
        dx=$signed({1'b0,filtered_x})-$signed({1'b0,CENTER_X});
        dy=$signed({1'b0,filtered_y})-$signed({1'b0,CENTER_Y});
        if(dx > -$signed({2'b0,DEADZONE}) && dx < $signed({2'b0,DEADZONE})) bend_calc=0;
        else begin
            bend_calc=dx*MAX_BEND/($signed({2'b0,10'd512})-$signed({2'b0,DEADZONE}));
            if(bend_calc>MAX_BEND) bend_calc=MAX_BEND;
            if(bend_calc< -MAX_BEND) bend_calc=-MAX_BEND;
        end
        if(dy > -$signed({2'b0,DEADZONE}) && dy < $signed({2'b0,DEADZONE})) mod_calc=0;
        else begin
            abs_dy = dy < 0 ? -dy : dy;
            if(abs_dy > 12'd480) abs_dy=12'd480;
            mod_calc=(abs_dy*16'd65535)/10'd480;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            x_acc<=0;y_acc<=0;x_count<=0;y_count<=0;filtered_x<=CENTER_X;filtered_y<=CENTER_Y;
            param_valid<=0;param_id<=`PARAM_PITCH_BEND;param_value<=16'h8000;
            pitch_bend<=0;modulation<=0;
        end else begin
            param_valid<=0;
            if(sample_valid && sample_channel==1) begin
                if(x_count==3) begin filtered_x<=deadzone_value((x_acc+ch1_x)>>2,CENTER_X);x_acc<=0;x_count<=0;end
                else begin x_acc<=x_acc+ch1_x;x_count<=x_count+1'b1;end
            end
            if(sample_valid && sample_channel==2) begin
                if(y_count==3) begin filtered_y<=deadzone_value((y_acc+ch2_y)>>2,CENTER_Y);y_acc<=0;y_count<=0;end
                else begin y_acc<=y_acc+ch2_y;y_count<=y_count+1'b1;end
            end
            if(sample_valid && (sample_channel==1 || sample_channel==2)) begin
                param_valid<=1;
                if(sample_channel==1) begin param_id<=`PARAM_PITCH_BEND;param_value<=bend_calc[15:0];pitch_bend<=bend_calc[15:0];end
                else begin param_id<=`PARAM_MODULATION;param_value<=mod_calc;modulation<=mod_calc;end
            end
        end
    end
endmodule

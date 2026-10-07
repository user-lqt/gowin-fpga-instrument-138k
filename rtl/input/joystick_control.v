`timescale 1ns/1ps
`include "event_defs.vh"

// Convert MCP3008 joystick samples into stable pitch-bend and modulation
// parameters. CH1 (VRx) is the pitch-bend axis; CH2 (VRy) is exposed as a
// modulation value for a future routing choice. The instrument top currently
// forwards only PARAM_PITCH_BEND because FSR owns PARAM_MODULATION.
module joystick_control #(
    parameter [9:0] CENTER_X=10'd512,
    parameter [9:0] CENTER_Y=10'd512,
    parameter [9:0] DEADZONE=10'd32,
    parameter integer MAX_BEND=8192
) (
    input wire clk,rst_n,
    input wire sample_valid,
    input wire sample_error,
    input wire [2:0] sample_channel,
    input wire [9:0] ch1_x,ch2_y,
    output reg param_valid,
    output reg [3:0] param_id,
    output reg [15:0] param_value,
    output reg signed [15:0] pitch_bend,
    output reg [15:0] modulation,
    output reg [9:0] filtered_x,filtered_y
);
    // Four samples per axis remove the largest one-conversion steps before
    // publishing an event. Twelve bits hold 4 * 1023 without overflow.
    reg [11:0] x_sum,y_sum;
    reg [1:0] x_count,y_count;
    wire [11:0] x_total=x_sum+{2'b0,ch1_x};
    wire [11:0] y_total=y_sum+{2'b0,ch2_y};
    wire [9:0] x_average=x_total[11:2];
    wire [9:0] y_average=y_total[11:2];
    // Constant divisors keep both directions calibrated when the measured
    // center is not exactly 512. Guard against a zero span at an invalid center.
    localparam integer DEADZONE_SIZE=DEADZONE;
    localparam integer X_NEG_SPAN=CENTER_X > DEADZONE ? CENTER_X-DEADZONE : 1;
    localparam integer X_POS_SPAN=1023-CENTER_X > DEADZONE ? 1023-CENTER_X-DEADZONE : 1;
    localparam integer Y_NEG_SPAN=CENTER_Y > DEADZONE ? CENTER_Y-DEADZONE : 1;
    localparam integer Y_POS_SPAN=1023-CENTER_Y > DEADZONE ? 1023-CENTER_Y-DEADZONE : 1;

    function [9:0] apply_deadzone;
        input [9:0] raw,center;
        reg signed [11:0] diff;
        begin
            diff=$signed({1'b0,raw})-$signed({1'b0,center});
            if(diff >= -DEADZONE_SIZE && diff <= DEADZONE_SIZE)
                apply_deadzone=center;
            else
                apply_deadzone=raw;
        end
    endfunction

    // Map the averaged X value to approximately +/-2 semitones. Removing the
    // deadzone before scaling makes the output start at zero smoothly.
    function signed [15:0] bend_from_raw;
        input [9:0] raw;
        integer signed diff;
        integer signed scaled;
        begin
            diff=$signed({1'b0,raw})-$signed({1'b0,CENTER_X});
            if(diff >= -DEADZONE_SIZE && diff <= DEADZONE_SIZE)
                scaled=0;
            else if(diff < 0)
                scaled=-((-diff-DEADZONE_SIZE)*MAX_BEND/X_NEG_SPAN);
            else
                // Match the signed Q12 audio interface: -8192..+8191.
                scaled=(diff-DEADZONE_SIZE)*(MAX_BEND-1)/X_POS_SPAN;
            bend_from_raw=scaled;
        end
    endfunction

    // Map Y displacement to 0..65535. The top-level queue intentionally
    // filters Y events while FSR is the active modulation source.
    function [15:0] modulation_from_raw;
        input [9:0] raw;
        integer signed diff;
        integer signed scaled;
        begin
            diff=$signed({1'b0,raw})-$signed({1'b0,CENTER_Y});
            if(diff >= -DEADZONE_SIZE && diff <= DEADZONE_SIZE)
                scaled=0;
            else if(diff < 0)
                scaled=(-diff-DEADZONE_SIZE)*65535/Y_NEG_SPAN;
            else
                scaled=(diff-DEADZONE_SIZE)*65535/Y_POS_SPAN;
            modulation_from_raw=scaled;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            x_sum<=0; y_sum<=0; x_count<=0; y_count<=0;
            filtered_x<=CENTER_X; filtered_y<=CENTER_Y;
            param_valid<=0; param_id<=`PARAM_PITCH_BEND; param_value<=0;
            pitch_bend<=0; modulation<=0;
        end else begin
            // Publish only after a complete four-sample average. This keeps
            // stale values out of the parameter queue.
            param_valid<=0;
            if(sample_error && sample_channel==3'd1) begin
                x_sum<=0; x_count<=0;
                filtered_x<=CENTER_X;
                pitch_bend<=0;
                // A failed SPI transaction must not leave a held note bent.
                if(pitch_bend!=0) begin
                    param_id<=`PARAM_PITCH_BEND;
                    param_value<=0;
                    param_valid<=1;
                end
            end else if(sample_valid && sample_channel==3'd1) begin
                if(x_count==2'd3) begin
                    filtered_x<=apply_deadzone(x_average,CENTER_X);
                    pitch_bend<=bend_from_raw(x_average);
                    param_id<=`PARAM_PITCH_BEND;
                    param_value<=bend_from_raw(x_average);
                    param_valid<=1;
                    x_sum<=0;
                    x_count<=0;
                end else begin
                    x_sum<=x_total;
                    x_count<=x_count+1'b1;
                end
            end
            if(sample_error && sample_channel==3'd2) begin
                y_sum<=0; y_count<=0;
                filtered_y<=CENTER_Y;
                modulation<=0;
                if(modulation!=0) begin
                    param_id<=`PARAM_MODULATION;
                    param_value<=0;
                    param_valid<=1;
                end
            end else if(sample_valid && sample_channel==3'd2) begin
                if(y_count==2'd3) begin
                    filtered_y<=apply_deadzone(y_average,CENTER_Y);
                    modulation<=modulation_from_raw(y_average);
                    param_id<=`PARAM_MODULATION;
                    param_value<=modulation_from_raw(y_average);
                    param_valid<=1;
                    y_sum<=0;
                    y_count<=0;
                end else begin
                    y_sum<=y_total;
                    y_count<=y_count+1'b1;
                end
            end
        end
    end
endmodule

`timescale 1ns/1ps
// RGB666 display. pixel_clk is a dedicated ~33.3 MHz PLL output.
// Synchronize the status inputs to pixel_clk before connecting them here.
module rgb_lcd_800x480 #(parameter integer ENABLE_DIAGNOSTICS = 0) (
    input wire pixel_clk,
    input wire rst_n,
    input wire [23:0] key_state,
    input wire [15:0] volume_value,
    input wire [15:0] instrument_value,
    input wire [31:0] diagnostic_state,
    output wire sc_clk,
    output reg sc_hs,
    output reg sc_vs,
    output reg sc_de,
    output wire frame_start,
    output reg [5:0] r_out,
    output reg [5:0] g_out,
    output reg [5:0] b_out
);
    // 800x480 @ ~60 Hz: 1056 pixels x 525 lines x 60 = 33.264 MHz.
    localparam H_ACTIVE=800, H_FRONT=40, H_SYNC=128, H_BACK=88;
    localparam V_ACTIVE=480, V_FRONT=13, V_SYNC=2, V_BACK=30;
    localparam H_TOTAL=H_ACTIVE+H_FRONT+H_SYNC+H_BACK;
    localparam V_TOTAL=V_ACTIVE+V_FRONT+V_SYNC+V_BACK;
    reg [10:0] h_count;
    reg [9:0] v_count;
    wire active = h_count < H_ACTIVE && v_count < V_ACTIVE;
    reg [4:0] key_index;
    reg [5:0] key_x;
    reg [23:0] frame_keys;
    reg [15:0] frame_volume, frame_instrument;
    reg [31:0] frame_diagnostic;
    wire [9:0] up_width = {1'b0, frame_diagnostic[31:24], 1'b0};
    wire [9:0] down_width = {1'b0, frame_diagnostic[23:16], 1'b0};
    wire [9:0] edge_width = {1'b0, frame_diagnostic[15:8], 1'b0};
    wire [9:0] volume_width = {frame_volume[6:0], 2'b0};
    reg [5:0] r_pixel, g_pixel, b_pixel;
    wire [8:0] marker_left = 9'd48 + frame_instrument[2:0] * 9'd40;
    wire [8:0] marker_right = marker_left + 9'd40;
    assign frame_start = h_count == 0 && v_count == 0;

    // Track the 33-pixel cells without division in the half-cycle pixel path.
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin key_index <= 0; key_x <= 0; end
        else if (h_count < 4 || h_count >= 795) begin key_index <= 0; key_x <= 0; end
        else if (key_x == 32) begin key_index <= key_index + 1'b1; key_x <= 0; end
        else key_x <= key_x + 1'b1;
    end

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin frame_keys <= 0; frame_volume <= 64; frame_instrument <= 0; frame_diagnostic <= 0; end
        else if (frame_start) begin
            frame_keys <= key_state;
            frame_volume <= volume_value;
            frame_instrument <= instrument_value;
            frame_diagnostic <= diagnostic_state;
        end
    end

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin h_count <= 0; v_count <= 0; end
        else if (h_count == H_TOTAL-1) begin
            h_count <= 0;
            if (v_count == V_TOTAL-1) v_count <= 0;
            else v_count <= v_count + 1'b1;
        end else h_count <= h_count + 1'b1;
    end

    assign sc_clk = pixel_clk;
    // Prepare all panel signals on the falling edge for rising-edge capture.
    always @(negedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            sc_de <= 0; sc_hs <= 1; sc_vs <= 1;
            r_out <= 0; g_out <= 0; b_out <= 0;
        end else begin
            sc_de <= active;
            sc_hs <= !(h_count >= H_ACTIVE+H_FRONT && h_count < H_ACTIVE+H_FRONT+H_SYNC);
            sc_vs <= !(v_count >= V_ACTIVE+V_FRONT && v_count < V_ACTIVE+V_FRONT+V_SYNC);
            r_out <= r_pixel; g_out <= g_pixel; b_out <= b_pixel;
        end
    end

    always @* begin
        r_pixel=0; g_pixel=0; b_pixel=0;
        if (active) begin
            // Quiet dark background and a narrow green volume meter.
            r_pixel=6'd5; g_pixel=6'd9; b_pixel=6'd13;
            if (v_count >= 66 && v_count < 88 && h_count >= 48 &&
                h_count < 48+volume_width) begin
                r_pixel=6'd12; g_pixel=6'd52; b_pixel=6'd27;
            end
            // 24 * 33 pixels fit between x=4 and x=795.
            if (v_count >= 145 && v_count < 415 && h_count >= 4 && h_count < 796 && key_index < 24 && key_x < 30) begin
                if (frame_keys[key_index]) begin
                    r_pixel=6'd8; g_pixel=6'd50; b_pixel=6'd44;
                end else begin
                    r_pixel=6'd55; g_pixel=6'd57; b_pixel=6'd55;
                end
                if (v_count >= 400) begin
                    r_pixel=r_pixel >> 1; g_pixel=g_pixel >> 1; b_pixel=b_pixel >> 1;
                end
            end
            // Instrument selection is shown by one of eight top markers.
            if (v_count >= 34 && v_count < 48 && h_count >= marker_left &&
                h_count < marker_right) begin
                r_pixel=6'd58; g_pixel=6'd39; b_pixel=6'd13;
            end
            if (ENABLE_DIAGNOSTICS != 0) begin
                // Left-to-right: A, B, switch (high=released), decoder ready.
                if (v_count >= 24 && v_count < 56 &&
                    ((h_count >= 560 && h_count < 584) ||
                     (h_count >= 608 && h_count < 632) ||
                     (h_count >= 656 && h_count < 680) ||
                     (h_count >= 704 && h_count < 728))) begin
                    r_pixel=6'd58; g_pixel=6'd10; b_pixel=6'd10;
                    if ((h_count < 584 && frame_diagnostic[0]) ||
                        (h_count >= 608 && h_count < 632 && frame_diagnostic[1]) ||
                        (h_count >= 656 && h_count < 680 && frame_diagnostic[2]) ||
                        (h_count >= 704 && frame_diagnostic[3])) begin
                        r_pixel=6'd10; g_pixel=6'd58; b_pixel=6'd10;
                    end
                end
                if (v_count >= 100 && v_count < 110 && h_count >= 48 && h_count < 48+edge_width)
                    begin r_pixel=6'd58; g_pixel=6'd39; b_pixel=6'd10; end
                if (v_count >= 114 && v_count < 124 && h_count >= 48 && h_count < 48+up_width)
                    begin r_pixel=6'd10; g_pixel=6'd54; b_pixel=6'd54; end
                if (v_count >= 128 && v_count < 138 && h_count >= 48 && h_count < 48+down_width)
                    begin r_pixel=6'd56; g_pixel=6'd12; b_pixel=6'd42; end
                if (v_count >= 66 && v_count < 88 && h_count >= 608 && h_count < 640)
                    begin r_pixel=6'd8; g_pixel=6'd20; b_pixel=(frame_diagnostic[7:4] == 0) ? 6'd20 : 6'd60; end
            end
        end
    end
endmodule

`timescale 1ns/1ps
// RGB666 display. pixel_clk is a dedicated ~33.3 MHz PLL output.
// Synchronize the status inputs to pixel_clk before connecting them here.
module rgb_lcd_800x480 (
    input wire pixel_clk,
    input wire rst_n,
    input wire [23:0] key_state,
    input wire [15:0] volume_value,
    input wire [15:0] instrument_value,
    output wire sc_clk,
    output wire sc_hs,
    output wire sc_vs,
    output wire sc_de,
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
    wire [4:0] key_index = h_count / 34;
    wire [5:0] key_x = h_count % 34;
    wire [9:0] volume_width = {volume_value[6:0], 2'b0};

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin h_count <= 0; v_count <= 0; end
        else if (h_count == H_TOTAL-1) begin
            h_count <= 0;
            if (v_count == V_TOTAL-1) v_count <= 0;
            else v_count <= v_count + 1'b1;
        end else h_count <= h_count + 1'b1;
    end

    assign sc_clk = pixel_clk;
    assign sc_de = active;
    assign sc_hs = !(h_count >= H_ACTIVE+H_FRONT &&
                     h_count < H_ACTIVE+H_FRONT+H_SYNC);
    assign sc_vs = !(v_count >= V_ACTIVE+V_FRONT &&
                     v_count < V_ACTIVE+V_FRONT+V_SYNC);

    always @* begin
        r_out=0; g_out=0; b_out=0;
        if (active) begin
            // Quiet dark background and a narrow green volume meter.
            r_out=6'd5; g_out=6'd9; b_out=6'd13;
            if (v_count >= 66 && v_count < 88 && h_count >= 48 &&
                h_count < 48+volume_width) begin
                r_out=6'd12; g_out=6'd52; b_out=6'd27;
            end
            // 24 fixed-width keys: lit keys are turquoise, inactive white.
            if (v_count >= 145 && v_count < 415 && key_index < 24 && key_x < 31) begin
                if (key_state[key_index]) begin
                    r_out=6'd8; g_out=6'd50; b_out=6'd44;
                end else begin
                    r_out=6'd55; g_out=6'd57; b_out=6'd55;
                end
                if (v_count >= 400) begin
                    r_out=r_out >> 1; g_out=g_out >> 1; b_out=b_out >> 1;
                end
            end
            // Instrument selection is shown by one of eight top markers.
            if (v_count >= 34 && v_count < 48 && h_count >= 48 &&
                h_count < 368 && ((h_count-48)/40) == instrument_value[2:0]) begin
                r_out=6'd58; g_out=6'd39; b_out=6'd13;
            end
        end
    end
endmodule

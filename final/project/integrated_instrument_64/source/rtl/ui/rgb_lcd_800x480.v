`timescale 1ns/1ps
// RGB666 display. pixel_clk is a dedicated ~33.3 MHz PLL output.
// Synchronize the status inputs to pixel_clk before connecting them here.
module rgb_lcd_800x480 #(parameter integer ENABLE_DIAGNOSTICS = 0,
    parameter integer ENABLE_B_MENU = 0, parameter integer ENABLE_STRIKE_DEBUG = 0) (
    input wire pixel_clk,
    input wire rst_n,
    input wire [23:0] key_state,
    input wire [15:0] volume_value,
    input wire [15:0] instrument_value,
    input wire [31:0] diagnostic_state,
    input wire [31:0] strike_debug,
    input wire control_menu,
    input wire [6:0] glide_value,effect_value,
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
    reg [31:0] frame_strike;
    reg debug_hit;
    integer dc,dx,dy,ch;
    reg [34:0] dg;
    function [34:0] debug_glyph;
        input integer c;
        begin
            case(c)
            48:debug_glyph={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
            49:debug_glyph={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
            50:debug_glyph={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
            51:debug_glyph={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
            52:debug_glyph={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
            53:debug_glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
            54:debug_glyph={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
            55:debug_glyph={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
            56:debug_glyph={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
            57:debug_glyph={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
            75:debug_glyph={5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001}; // K
            68:debug_glyph=glyph(3);
            84:debug_glyph={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
            86:debug_glyph={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
            65:debug_glyph={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
            66:debug_glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
            70:debug_glyph=glyph(5);
            83:debug_glyph={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
            76:debug_glyph=glyph(1);
            79:debug_glyph={5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
            87:debug_glyph={5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
            77:debug_glyph={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
            61:debug_glyph={5'b00000,5'b00000,5'b11111,5'b00000,5'b11111,5'b00000,5'b00000};
            default:debug_glyph=0;
            endcase
        end
    endfunction
    // Format: K=01 DT=0000MS V=127 FAST A=1 B=1
    always @* begin
        debug_hit=0;dx=0;dy=0;ch=32;dg=0;
        for(dc=0;dc<34;dc=dc+1) begin
            ch=32;
            case(dc)
            0:ch=75; 1:ch=61;
            2:ch=48+(frame_strike[28:24]+1)/10;
            3:ch=48+(frame_strike[28:24]+1)%10;
            5:ch=68;6:ch=84;7:ch=61;
            8:ch=48+(frame_strike[15:0]/1000)%10;
            9:ch=48+(frame_strike[15:0]/100)%10;
            10:ch=48+(frame_strike[15:0]/10)%10;
            11:ch=48+frame_strike[15:0]%10;
            12:ch=77;13:ch=83;
            15:ch=86;16:ch=61;
            17:ch=48+frame_strike[23:16]/100;
            18:ch=48+(frame_strike[23:16]/10)%10;
            19:ch=48+frame_strike[23:16]%10;
            21:ch=frame_strike[23:16]>=92 ? 70 : 83;
            22:ch=frame_strike[23:16]>=92 ? 65 : 76;
            23:ch=frame_strike[23:16]>=92 ? 83 : 79;
            24:ch=frame_strike[23:16]>=92 ? 84 : 87;
            26:ch=65;27:ch=61;28:ch=48+frame_strike[30];
            30:ch=66;31:ch=61;32:ch=48+frame_strike[29];
            endcase
            if(v_count>=104 && v_count<125 && h_count>=48+dc*21 && h_count<63+dc*21) begin
                dx=(h_count-48-dc*21)/3;dy=(v_count-104)/3;
                dg=debug_glyph(ch);
                debug_hit=debug_hit | dg[34-dy*5-dx];
            end
        end
    end
    reg frame_menu;
    reg [6:0] frame_glide,frame_effect;
    integer text_cell,text_x,text_y;
    reg text_hit;
    reg [34:0] text_glyph;
    function [34:0] glyph;
        input integer letter;
        begin
            case(letter)
                0: glyph={5'b01110,5'b10001,5'b10000,5'b10111,5'b10001,5'b10001,5'b01110}; // G
                1: glyph={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111}; // L
                2: glyph={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111}; // I
                3: glyph={5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110}; // D
                4: glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111}; // E
                5: glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000}; // F
                default: glyph={5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001}; // X
            endcase
        end
    endfunction
    wire [9:0] up_width = {1'b0, frame_diagnostic[31:24], 1'b0};
    wire [9:0] down_width = {1'b0, frame_diagnostic[23:16], 1'b0};
    wire [9:0] edge_width = {1'b0, frame_diagnostic[15:8], 1'b0};
    wire [9:0] volume_width = {frame_volume[6:0], 2'b0};
    reg [5:0] r_pixel, g_pixel, b_pixel;
    reg [5:0] r_prepared,g_prepared,b_prepared;
    reg de_prepared,hs_prepared,vs_prepared;
    wire [8:0] marker_left = 9'd48 + frame_instrument[2:0] * 9'd40;
    wire [8:0] marker_right = marker_left + 9'd40;
    assign frame_start = h_count == 0 && v_count == 0;
    always @* begin
        text_hit=0;text_x=0;text_y=0;text_glyph=0;
        for(text_cell=0;text_cell<7;text_cell=text_cell+1) begin
            if(v_count>=430 && v_count<458 &&
                ((text_cell<5 && h_count>=48+text_cell*24 && h_count<68+text_cell*24) ||
                 (text_cell>=5 && h_count>=448+(text_cell-5)*24 && h_count<468+(text_cell-5)*24))) begin
                text_x=(text_cell<5 ? h_count-48-text_cell*24 : h_count-448-(text_cell-5)*24)>>2;
                text_y=(v_count-430)>>2;
                text_glyph=glyph(text_cell);
                text_hit=text_hit | text_glyph[34-text_y*5-text_x];
            end
        end
    end

    // Track the 33-pixel cells without division in the half-cycle pixel path.
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin key_index <= 0; key_x <= 0; end
        else if (h_count < 4 || h_count >= 795) begin key_index <= 0; key_x <= 0; end
        else if (key_x == 32) begin key_index <= key_index + 1'b1; key_x <= 0; end
        else key_x <= key_x + 1'b1;
    end

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin frame_keys <= 0; frame_volume <= 64; frame_instrument <= 0; frame_diagnostic <= 0;
            frame_menu<=0;frame_glide<=0;frame_effect<=0;frame_strike<=0;end
        else if (frame_start) begin
            frame_keys <= key_state;
            frame_volume <= volume_value;
            frame_instrument <= instrument_value;
            frame_diagnostic <= diagnostic_state;
            frame_strike <= strike_debug;
            frame_menu<=control_menu;frame_glide<=glide_value;frame_effect<=effect_value;
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
    // Give rendering a full pixel period, rather than half a period. Delay
    // data and all timing signals together by one pixel to retain alignment.
    always @(posedge pixel_clk or negedge rst_n) begin
        if(!rst_n) begin
            r_prepared<=0;g_prepared<=0;b_prepared<=0;
            de_prepared<=0;hs_prepared<=1;vs_prepared<=1;
        end else begin
            r_prepared<=r_pixel;g_prepared<=g_pixel;b_prepared<=b_pixel;
            de_prepared<=active;
            hs_prepared<=!(h_count>=H_ACTIVE+H_FRONT && h_count<H_ACTIVE+H_FRONT+H_SYNC);
            vs_prepared<=!(v_count>=V_ACTIVE+V_FRONT && v_count<V_ACTIVE+V_FRONT+V_SYNC);
        end
    end
    // Prepare all panel signals on the falling edge for rising-edge capture.
    always @(negedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            sc_de <= 0; sc_hs <= 1; sc_vs <= 1;
            r_out <= 0; g_out <= 0; b_out <= 0;
        end else begin
            sc_de <= de_prepared;
            sc_hs <= hs_prepared;
            sc_vs <= vs_prepared;
            r_out <= r_prepared; g_out <= g_prepared; b_out <= b_prepared;
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
            if(ENABLE_B_MENU != 0) begin
                if(v_count>=426 && v_count<462 &&
                    ((h_count>=40 && h_count<176)||(h_count>=440 && h_count<504))) begin
                    r_pixel=6'd8;g_pixel=6'd18;b_pixel=6'd24;
                    if((h_count<176 && !frame_menu)||(h_count>=440 && frame_menu)) begin
                        r_pixel=6'd8;g_pixel=6'd38;b_pixel=6'd32;
                    end
                end
                if(text_hit) begin r_pixel=63;g_pixel=63;b_pixel=63;end
                // Separate persistent settings, 0..127 -> 0..254 pixels.
                if(v_count>=466 && v_count<476 &&
                    ((h_count>=48 && h_count<48+{frame_glide,1'b0}) ||
                     (h_count>=448 && h_count<448+{frame_effect,1'b0}))) begin
                    r_pixel=6'd12;g_pixel=6'd54;b_pixel=6'd42;
                end
            end
            if(ENABLE_STRIKE_DEBUG != 0 && v_count>=98 && v_count<134) begin
                r_pixel=5;g_pixel=9;b_pixel=13;
                if(debug_hit && frame_strike[31]) begin
                    r_pixel=frame_strike[23:16]>=92 ? 6'd15 : 6'd63;
                    g_pixel=frame_strike[23:16]>=92 ? 6'd63 : 6'd38;
                    b_pixel=6'd20;
                end
            end
        end
    end
endmodule

`timescale 1ns/1ps
// Compact 5x7 glyphs in an 8x16 cell, with each row doubled vertically.
module oled_font (
    input wire [7:0] character,
    input wire [2:0] column,
    input wire bottom,
    output reg [7:0] pixels
);
    reg [39:0] glyph;
    reg [7:0] stripe;
    reg [15:0] expanded;
    integer i;
    always @* begin
        case (character)
            "0": glyph=40'h3e5149453e;
            "1": glyph=40'h00427f4000;
            "2": glyph=40'h4261514946;
            "3": glyph=40'h2141454b31;
            "4": glyph=40'h1814127f10;
            "5": glyph=40'h2745454539;
            "6": glyph=40'h3c4a494930;
            "7": glyph=40'h0171090503;
            "8": glyph=40'h3649494936;
            "9": glyph=40'h064949291e;
            "V": glyph=40'h1f2040201f;
            "O": glyph=40'h3e4141413e;
            "L": glyph=40'h7f40404040;
            "I": glyph=40'h00417f4100;
            "N": glyph=40'h7f0408107f;
            "S": glyph=40'h4649494931;
            "C": glyph=40'h3e41414122;
            "E": glyph=40'h7f49494941;
            "R": glyph=40'h7f09192946;
            ":": glyph=40'h0036360000;
            ">": glyph=40'h0041221408;
            default: glyph=0;
        endcase
        case (column)
            1: stripe=glyph[39:32];
            2: stripe=glyph[31:24];
            3: stripe=glyph[23:16];
            4: stripe=glyph[15:8];
            5: stripe=glyph[7:0];
            default: stripe=0;
        endcase
        for (i=0;i<8;i=i+1) begin
            expanded[2*i]=stripe[i]; expanded[2*i+1]=stripe[i];
        end
        pixels=bottom ? expanded[15:8] : expanded[7:0];
    end
endmodule

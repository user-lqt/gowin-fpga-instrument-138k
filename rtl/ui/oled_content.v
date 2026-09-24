`timescale 1ns/1ps
// 4 rows x 16 ASCII characters, intended for an 8x16 font on 128x64 OLED.
// B provides content only. C implements font lookup and SSD1306/I2C timing.
// C pulses frame_start for one clk BEFORE reading character addresses 0..63.
// Snapshot remains unchanged for the whole frame despite parameter changes.
// No pixel bytes and no I2C pins here. char_data is combinational.
// Line 0: ">VOL:064        " (16 chars, selected marker).
// Instrument IDs use 5 decimal digits to cover the full 16-bit interface.
module oled_content (
    input wire clk, rst_n, frame_start,
    input wire [5:0] char_addr,
    input wire [3:0] ui_page,
    input wire [15:0] volume_value, instrument_value,
    input wire [5:0] active_voice_count,
    input wire input_ready, audio_locked, i2s_active, system_error,
    output reg [7:0] char_data
);
    reg [3:0] page;
    reg [15:0] volume, instrument;
    reg [5:0] voices;
    reg ready, locked, streaming, error;
    function [7:0] digit;
        input integer n;
        begin digit = 8'd48 + (n % 10); end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            page <= 0; volume <= 64; instrument <= 0; voices <= 0;
            ready <= 0; locked <= 0; streaming <= 0; error <= 0;
        end else if (frame_start) begin
            page <= ui_page; volume <= volume_value; instrument <= instrument_value;
            voices <= active_voice_count; ready <= input_ready; locked <= audio_locked;
            streaming <= i2s_active; error <= system_error;
        end
    end
    always @* begin
        char_data = " ";
        case (char_addr)
             0: char_data = (page == 0) ? ">" : " ";
             1: char_data = "V"; 2: char_data = "O"; 3: char_data = "L"; 4: char_data = ":";
             5: char_data = digit(volume / 100);
             6: char_data = digit(volume / 10);
             7: char_data = digit(volume);
            16: char_data = (page == 1) ? ">" : " ";
            17: char_data = "I"; 18: char_data = "N"; 19: char_data = "S"; 20: char_data = ":";
            21: char_data = digit(instrument / 10000);
            22: char_data = digit(instrument / 1000);
            23: char_data = digit(instrument / 100);
            24: char_data = digit(instrument / 10);
            25: char_data = digit(instrument);
            33: char_data = "V"; 34: char_data = "O"; 35: char_data = "I";
            36: char_data = "C"; 37: char_data = "E"; 38: char_data = ":";
            39: char_data = digit(voices / 10); 40: char_data = digit(voices);
            48: char_data = "R"; 49: char_data = ready ? "1" : "0";
            51: char_data = "L"; 52: char_data = locked ? "1" : "0";
            54: char_data = "I"; 55: char_data = streaming ? "1" : "0";
            57: char_data = "E"; 58: char_data = error ? "1" : "0";
            default: char_data = " ";
        endcase
    end
endmodule

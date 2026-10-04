`timescale 1ns/1ps
// Notification only: C must latch a pending redraw until it can service it.
// Active voice count comes from A, not the number of physically pressed keys.
module ui_state (
    input wire clk, rst_n,
    input wire [3:0] ui_page,
    input wire [15:0] volume_value, instrument_value,
    input wire [5:0] active_voice_count,
    input wire input_ready, audio_locked, i2s_active, system_error,
    output reg ui_dirty
);
    wire [45:0] state_now = {ui_page, volume_value, instrument_value,
        active_voice_count, input_ready, audio_locked, i2s_active, system_error};
    reg [45:0] previous;
    reg initialized;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin previous <= 0; initialized <= 0; ui_dirty <= 0; end
        else begin
            ui_dirty <= !initialized || (state_now != previous);
            previous <= state_now;
            initialized <= 1;
        end
    end
endmodule

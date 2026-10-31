`timescale 1ns/1ps
`include "../input/input_defs.vh"
// B2 parameter manager, not audio gain processing.
// ENABLE_INSTRUMENT=1 enables page switching and a second startup event.
// INSTRUMENT_COUNT: 1..65536, instrument starts at 0 and clamps at either end.
// ui_page: 0=volume, 1=instrument. Select has priority over simultaneous rotation.
// Switching pages only sets ui_dirty; it does not send an audio parameter event.
// Legal configuration: 0 <= DEFAULT_VOLUME <= MAX_VOLUME, VOLUME_STEP >= 1.
// UI values default to 0..127, 64, step 1; volume param payload is 0..65535.
// First active clock publishes the default; step inputs on that clock are ignored.
// Thereafter each asserted step is an event (no edge detector, no auto-repeat).
// Simultaneous up/down cancel. Saturated/no-op requests publish no update.
// Receiver must accept EVERY clk with param_valid=1, including adjacent clocks.
// No ready/backpressure: receiver must share reset or separately request resync.
// ui_dirty is a one-clock notification; display logic must latch pending updates.
// ROTATE_VOLUME_PRESS_TIMBRE=1 keeps page 0, rotates volume and cycles timbre
// on a press. Its deferred timbre event preserves a coincident volume step.
module parameter_manager #(
    parameter [15:0] MAX_VOLUME = 16'd127,
    parameter [15:0] DEFAULT_VOLUME = 16'd64,
    parameter [15:0] VOLUME_STEP = 16'd1,
    parameter integer ENABLE_INSTRUMENT = 0,
    parameter integer INSTRUMENT_COUNT = 4,
    parameter integer ROTATE_VOLUME_PRESS_TIMBRE = 0,
    parameter [15:0] DEFAULT_INSTRUMENT = 0,
    parameter integer ENABLE_REMOTE = 0
) (
    input wire clk,
    input wire rst_n,
    input wire step_up,
    input wire step_down,
    output reg [15:0] volume_value,
    output reg param_valid,
    output reg [3:0] param_id,
    output reg [15:0] param_value,
    output wire [15:0] ui_param_value,
    output reg ui_dirty,
    input wire select_press,
    output reg [15:0] instrument_value,
    output reg [3:0] ui_page,
    // Absolute UI values from a validated remote command. Default-disabled
    // so legacy instances with these new ports unconnected remain unchanged.
    input wire remote_valid,
    input wire [3:0] remote_id,
    input wire [15:0] remote_value
);
    reg initialized;
    reg instrument_pending;
    reg [15:0] next_volume;
    reg [15:0] next_instrument;
    wire [16:0] increased = {1'b0, volume_value} + {1'b0, VOLUME_STEP};
    wire remote_volume = (ENABLE_REMOTE != 0) && remote_valid
        && remote_id == `PARAM_VOLUME && remote_value <= MAX_VOLUME;
    wire remote_instrument = (ENABLE_REMOTE != 0) && remote_valid
        && remote_id == `PARAM_INSTRUMENT && (ENABLE_INSTRUMENT != 0)
        && remote_value < INSTRUMENT_COUNT;
    function [15:0] audio_volume;
        input [15:0] ui_volume;
        // 65535*65535 + floor(65535/2) fits unsigned 32 bits.
        reg [31:0] scaled;
        reg [31:0] quotient;
        reg [15:0] base_gain;
        begin
            if (MAX_VOLUME == 0) audio_volume = 0;
            else if (MAX_VOLUME == 127) begin
                // Valid UI range is 0..127. 65535 = 516*127 + 3.
                // Exact rounded mapping, with only shifts and comparisons.
                base_gain=({9'd0,ui_volume[6:0]} << 9)+
                          ({9'd0,ui_volume[6:0]} << 2);
                audio_volume=base_gain+(ui_volume <= 21 ? 16'd0 :
                    ui_volume <= 63 ? 16'd1 : ui_volume <= 105 ? 16'd2 : 16'd3);
            end
            else begin
                scaled = {16'd0, ui_volume} * 32'd65535 + (MAX_VOLUME / 2);
                quotient = scaled / MAX_VOLUME;
                audio_volume = quotient[15:0];
            end
        end
    endfunction
    assign ui_param_value = (ui_page == 0) ? volume_value : instrument_value;
    always @* begin
        next_instrument = instrument_value;
        if (step_up && !step_down && instrument_value < INSTRUMENT_COUNT - 1)
            next_instrument = instrument_value + 1'b1;
        else if (step_down && !step_up && instrument_value != 0)
            next_instrument = instrument_value - 1'b1;
        next_volume = volume_value;
        if (step_up && !step_down) begin
            if (increased > {1'b0, MAX_VOLUME}) next_volume = MAX_VOLUME;
            else next_volume = increased[15:0];
        end else if (step_down && !step_up) begin
            if (volume_value < VOLUME_STEP) next_volume = 0;
            else next_volume = volume_value - VOLUME_STEP;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            initialized <= 0;
            instrument_pending <= (ENABLE_INSTRUMENT != 0);
            instrument_value <= DEFAULT_INSTRUMENT;
            ui_page <= 0;
            param_id <= `PARAM_VOLUME;
            volume_value <= DEFAULT_VOLUME;
            param_value <= audio_volume(DEFAULT_VOLUME);
            param_valid <= 0;
            ui_dirty <= 0;
        end else begin
            param_valid <= 0;
            ui_dirty <= 0;
            if (!initialized) begin
                initialized <= 1;
                param_value <= audio_volume(volume_value);
                param_valid <= 1;
                ui_dirty <= 1;
            end else if (remote_volume) begin
                // Same-parameter collisions prefer the remote command. A
                // simultaneous local timbre press is retained for the next clk.
                if (remote_value != volume_value) begin
                    volume_value <= remote_value;
                    param_id <= `PARAM_VOLUME;
                    param_value <= audio_volume(remote_value);
                    param_valid <= 1;
                    ui_dirty <= 1;
                end
                if (ROTATE_VOLUME_PRESS_TIMBRE != 0 && select_press
                        && ENABLE_INSTRUMENT != 0) begin
                    instrument_value <= (instrument_value >= INSTRUMENT_COUNT-1)
                        ? 16'd0 : instrument_value + 1'b1;
                    instrument_pending <= 1;
                    ui_dirty <= 1;
                end
            end else if (remote_instrument) begin
                instrument_value <= remote_value;
                ui_dirty <= 1;
                if (ROTATE_VOLUME_PRESS_TIMBRE != 0 && next_volume != volume_value) begin
                    volume_value <= next_volume;
                    param_id <= `PARAM_VOLUME;
                    param_value <= audio_volume(next_volume);
                    param_valid <= 1;
                    instrument_pending <= 1;
                end else begin
                    param_id <= `PARAM_INSTRUMENT;
                    param_value <= remote_value;
                    param_valid <= 1;
                    instrument_pending <= 0;
                end
            end else if (instrument_pending) begin
                instrument_pending <= 0;
                param_id <= `PARAM_INSTRUMENT;
                param_value <= instrument_value;
                param_valid <= 1;
            end else if (ROTATE_VOLUME_PRESS_TIMBRE != 0) begin
                // Queue the timbre event separately so a simultaneous volume
                // step and press both reach the single parameter output.
                if ((ENABLE_INSTRUMENT != 0) && select_press) begin
                    instrument_value <= (instrument_value >= INSTRUMENT_COUNT-1)
                        ? 16'd0 : instrument_value + 1'b1;
                    instrument_pending <= 1;
                    ui_dirty <= 1;
                end
                if (next_volume != volume_value) begin
                    volume_value <= next_volume;
                    param_id <= `PARAM_VOLUME;
                    param_value <= audio_volume(next_volume);
                    param_valid <= 1;
                    ui_dirty <= 1;
                end
            end else if ((ENABLE_INSTRUMENT != 0) && select_press) begin
                ui_page <= (ui_page == 0) ? 4'd1 : 4'd0;
                ui_dirty <= 1;
            end else if ((ui_page == 0) && (next_volume != volume_value)) begin
                volume_value <= next_volume;
                param_id <= `PARAM_VOLUME;
                param_value <= audio_volume(next_volume);
                param_valid <= 1;
                ui_dirty <= 1;
            end else if ((ui_page == 1) && (next_instrument != instrument_value)) begin
                instrument_value <= next_instrument;
                param_id <= `PARAM_INSTRUMENT;
                param_value <= next_instrument;
                param_valid <= 1;
                ui_dirty <= 1;
            end
        end
    end
endmodule

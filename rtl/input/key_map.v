`timescale 1ns/1ps
`include "input_defs.vh"
// Input is the DEBOUNCED state from matrix_keyboard, not raw columns/pulses.
// Contract: each key state must persist for at least 16 clk cycles.
// matrix_keyboard satisfies this: updates are >= 4*ROW_CYCLES >= 16 cycles apart.
// A round-robin check visits every key once in 16 cycles, so simultaneous
// changes are serialized without a FIFO or loss under this timing contract.
// Receiver MUST accept an event at EVERY rising clk edge with event_valid=1.
// Consecutive valid cycles can carry different events; do not edge-detect valid.
// A sample_tick-only consumer needs a queue in the system integration layer.
module key_map #(
    parameter integer BASE_NOTE = 60, // Legal range: 0..112 (16 MIDI notes).
    parameter [7:0] NOTE_VELOCITY = 8'd127
) (
    input wire clk,
    input wire rst_n,
    input wire [15:0] key_state,
    output reg event_valid,
    output reg [1:0] event_type,
    output reg [6:0] note_id,
    output reg [7:0] velocity
);
    reg [15:0] reported_state;
    reg [3:0] cursor;
    localparam [6:0] BASE = BASE_NOTE;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reported_state <= 0;
            cursor <= 0;
            event_valid <= 0;
            event_type <= `EVENT_NONE;
            note_id <= 0;
            velocity <= 0;
        end else begin
            cursor <= cursor + 1'b1;
            event_valid <= 0;
            if (key_state[cursor] != reported_state[cursor]) begin
                reported_state[cursor] <= key_state[cursor];
                event_valid <= 1;
                event_type <= key_state[cursor] ? `EVENT_NOTE_ON : `EVENT_NOTE_OFF;
                note_id <= BASE + {3'b000, cursor};
                velocity <= key_state[cursor] ? NOTE_VELOCITY : 8'd0;
            end
        end
    end
endmodule

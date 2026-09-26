`include "event_defs.vh"

module voice_allocator #(
    parameter integer VOICES = 4
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  sample_tick,
    input  wire                  event_valid,
    input  wire [1:0]            event_type,
    input  wire [6:0]            note_id,
    input  wire [7:0]            velocity,
    input  wire [VOICES-1:0]     voice_active,
    output reg  [VOICES-1:0]     voice_note_on,
    output reg  [VOICES-1:0]     voice_note_off,
    output reg  [VOICES-1:0]     key_down,
    output reg  [VOICES*7-1:0]   voice_note_id,
    output reg  [VOICES*8-1:0]   voice_velocity,
    output reg                   full_pulse
);
    // event_valid is the one-cycle dequeue pulse from audio_core's event FIFO.
    // This block must not queue the raw B input a second time.

    integer matching;
    integer available;
    integer k;

    always @(*) begin
        matching = -1;
        available = -1;
        for (k = 0; k < VOICES; k = k + 1) begin
            if (matching == -1 && key_down[k] &&
                voice_note_id[k*7 +: 7] == note_id)
                matching = k;
            if (available == -1 && !voice_active[k] && !key_down[k])
                available = k;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            voice_note_on    <= {VOICES{1'b0}};
            voice_note_off   <= {VOICES{1'b0}};
            key_down         <= {VOICES{1'b0}};
            voice_note_id    <= {(VOICES*7){1'b0}};
            voice_velocity   <= {(VOICES*8){1'b0}};
            full_pulse       <= 1'b0;
        end else begin
            voice_note_on  <= {VOICES{1'b0}};
            voice_note_off <= {VOICES{1'b0}};
            full_pulse     <= 1'b0;

            if (sample_tick && event_valid) begin
                case (event_type)
                    `EVENT_NOTE_ON: begin
                        if (velocity != 8'd0) begin
                            if (matching != -1) begin
                                voice_note_on[matching] <= 1'b1;
                                voice_velocity[matching*8 +: 8] <= velocity;
                                key_down[matching] <= 1'b1;
                            end else if (available != -1) begin
                                voice_note_on[available] <= 1'b1;
                                voice_note_id[available*7 +: 7] <= note_id;
                                voice_velocity[available*8 +: 8] <= velocity;
                                key_down[available] <= 1'b1;
                            end else begin
                                full_pulse <= 1'b1;
                            end
                        end
                    end
                    `EVENT_NOTE_OFF: begin
                        if (matching != -1) begin
                            voice_note_off[matching] <= 1'b1;
                            key_down[matching] <= 1'b0;
                        end
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule

`timescale 1ns/1ps
`include "input_defs.vh"
// Debounces 48 row-major contacts, measures A-to-B travel in scan frames,
// and serializes NOTE events at a bounded rate for the audio queue.
module keyboard_24_dual #(
    parameter integer DEBOUNCE_FRAMES = 2,
    parameter integer AB_MAX_FRAMES = 40,
    parameter integer EVENT_INTERVAL_CYCLES = 256
) (
    input wire clk,
    input wire rst_n,
    input wire scan_valid,
    input wire [47:0] contact_raw,
    output reg event_valid,
    output reg [1:0] event_type,
    output reg [4:0] key_id,
    output reg [7:0] velocity,
    output reg [23:0] key_state
);
    function integer width_for;
        input integer n;
        integer v;
        begin
            v=n-1; width_for=0;
            while (v>0) begin width_for=width_for+1; v=v>>1; end
            if (width_for<1) width_for=1;
        end
    endfunction
    localparam integer DBW = width_for(DEBOUNCE_FRAMES);
    localparam integer ABW = width_for(AB_MAX_FRAMES+1);
    localparam integer EW = width_for(EVENT_INTERVAL_CYCLES);
    reg [EW-1:0] event_wait;
    reg [47:0] stable_contacts;
    reg [DBW-1:0] db_count [0:47];
    reg [ABW-1:0] ab_age [0:23];
    reg [23:0] pending_on, pending_off;
    reg [7:0] pending_velocity [0:23];
    reg [5:0] event_cursor;
    integer i, k, row_a, row_b, col;
    reg a_next, b_next;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stable_contacts <= 0;
            key_state <= 0;
            pending_on <= 0;
            pending_off <= 0;
            event_valid <= 0;
            event_type <= `EVENT_NONE;
            key_id <= 0;
            velocity <= 0;
            event_cursor <= 0;
            event_wait <= 0;
            for (i=0;i<48;i=i+1) db_count[i] <= 0;
            for (i=0;i<24;i=i+1) begin ab_age[i] <= 0; pending_velocity[i] <= 0; end
        end else begin
            event_valid <= 0;

            // Pace events to the audio consumer's one-event-per-sample rate.
            if (event_wait != 0) event_wait <= event_wait - 1'b1;
            if (event_cursor == 6'd23) event_cursor <= 0;
            else event_cursor <= event_cursor + 1'b1;
            if (!scan_valid && event_wait == 0 && pending_on[event_cursor[4:0]]) begin
                event_wait <= EVENT_INTERVAL_CYCLES-1;
                event_valid <= 1;
                event_type <= `EVENT_NOTE_ON;
                key_id <= event_cursor[4:0];
                velocity <= pending_velocity[event_cursor[4:0]];
                pending_on[event_cursor[4:0]] <= 0;
            end else if (!scan_valid && event_wait == 0 && pending_off[event_cursor[4:0]]) begin
                event_wait <= EVENT_INTERVAL_CYCLES-1;
                event_valid <= 1;
                event_type <= `EVENT_NOTE_OFF;
                key_id <= event_cursor[4:0];
                velocity <= 0;
                pending_off[event_cursor[4:0]] <= 0;
            end

            if (scan_valid) begin
                // Per-contact consecutive-frame debounce.
                for (i=0;i<48;i=i+1) begin
                    if (contact_raw[i] == stable_contacts[i]) db_count[i] <= 0;
                    else if (db_count[i] >= DEBOUNCE_FRAMES-1) begin
                        stable_contacts[i] <= contact_raw[i];
                        db_count[i] <= 0;
                    end else db_count[i] <= db_count[i] + 1'b1;
                end

                // Include a contact's debounced transition in this frame.
                for (k=0;k<24;k=k+1) begin
                    row_a=(k/6)*2; row_b=row_a+1; col=k%6;
                    a_next = (contact_raw[row_a*6+col] != stable_contacts[row_a*6+col] &&
                              db_count[row_a*6+col] >= DEBOUNCE_FRAMES-1) ?
                              contact_raw[row_a*6+col] : stable_contacts[row_a*6+col];
                    b_next = (contact_raw[row_b*6+col] != stable_contacts[row_b*6+col] &&
                              db_count[row_b*6+col] >= DEBOUNCE_FRAMES-1) ?
                              contact_raw[row_b*6+col] : stable_contacts[row_b*6+col];
                    if (a_next && !stable_contacts[row_a*6+col] && !key_state[k])
                        ab_age[k] <= 1;
                    else if (a_next && !key_state[k] && ab_age[k] != 0 &&
                             ab_age[k] < AB_MAX_FRAMES)
                        ab_age[k] <= ab_age[k] + 1'b1;
                    if (b_next && a_next && !key_state[k] &&
                        (ab_age[k] != 0 || !stable_contacts[row_a*6+col])) begin
                        pending_on[k] <= 1;
                        key_state[k] <= 1;
                        if (ab_age[k] <= 1) pending_velocity[k] <= 8'd127;
                        else if (ab_age[k] >= AB_MAX_FRAMES) pending_velocity[k] <= 8'd1;
                        else pending_velocity[k] <= 8'd127 - ((ab_age[k]-1)*126)/(AB_MAX_FRAMES-1);
                        ab_age[k] <= 0;
                    end
                    if (!a_next && !b_next) begin
                        if (key_state[k]) begin
                            pending_off[k] <= 1;
                            key_state[k] <= 0;
                        end
                        ab_age[k] <= 0;
                    end else if (!a_next && !key_state[k]) ab_age[k] <= 0;
                end
            end
        end
    end
endmodule

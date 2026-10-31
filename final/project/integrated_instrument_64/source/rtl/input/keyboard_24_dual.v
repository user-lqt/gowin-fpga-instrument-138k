`timescale 1ns/1ps
`include "input_defs.vh"
// Debounces 48 row-major contacts, measures A-to-B travel in scan frames,
// and serializes NOTE events at a bounded rate for the audio queue.
module keyboard_24_dual #(
    // Keep the generic defaults small for fast unit tests; the hardware top
    // overrides them with the longer press/release filters below.
    parameter integer DEBOUNCE_FRAMES = 2,
    parameter integer RELEASE_DEBOUNCE_FRAMES = 2,
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
    output reg [23:0] key_state,
    output reg [15:0] measured_frames,
    output reg [4:0] measured_key,
    output reg measured_valid,
    output wire [7:0] measured_velocity
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
    localparam integer DBW = width_for(DEBOUNCE_FRAMES > RELEASE_DEBOUNCE_FRAMES ? DEBOUNCE_FRAMES : RELEASE_DEBOUNCE_FRAMES);
    localparam integer ABW = width_for(AB_MAX_FRAMES+1);
    localparam integer EW = width_for(EVENT_INTERVAL_CYCLES);
    reg [EW-1:0] event_wait;
    reg [47:0] stable_contacts;
    reg [DBW-1:0] db_count [0:47];
    reg [ABW-1:0] ab_age [0:23];
    reg [23:0] travel_started, strike_measured;
    reg [7:0] strike_velocity [0:23];
    // Four per-key breakpoints: hard median, hard/medium midpoint,
    // medium median, and medium/soft midpoint (all in scan frames).
    function [43:0] key_velocity_limits;
        input integer key;
        begin
            case (key)
                0: key_velocity_limits={11'd4,11'd16,11'd28,11'd128};
                1: key_velocity_limits={11'd9,11'd69,11'd130,11'd301};
                2: key_velocity_limits={11'd4,11'd10,11'd16,11'd36};
                3: key_velocity_limits={11'd4,11'd12,11'd20,11'd38};
                4: key_velocity_limits={11'd12,11'd75,11'd139,11'd239};
                5: key_velocity_limits={11'd19,11'd52,11'd84,11'd381};
                6: key_velocity_limits={11'd27,11'd79,11'd132,11'd256};
                7: key_velocity_limits={11'd25,11'd74,11'd124,11'd256};
                8: key_velocity_limits={11'd4,11'd8,11'd12,11'd19};
                9: key_velocity_limits={11'd6,11'd29,11'd53,11'd201};
                10: key_velocity_limits={11'd3,11'd9,11'd16,11'd147};
                11: key_velocity_limits={11'd3,11'd6,11'd10,11'd59};
                12: key_velocity_limits={11'd17,11'd71,11'd125,11'd445};
                13: key_velocity_limits={11'd10,11'd67,11'd124,11'd731};
                14: key_velocity_limits={11'd11,11'd52,11'd93,11'd239};
                15: key_velocity_limits={11'd15,11'd49,11'd84,11'd172};
                16: key_velocity_limits={11'd8,11'd32,11'd57,11'd116};
                17: key_velocity_limits={11'd1,11'd3,11'd6,11'd59};
                18: key_velocity_limits={11'd9,11'd24,11'd40,11'd120};
                19: key_velocity_limits={11'd6,11'd11,11'd17,11'd47};
                20: key_velocity_limits={11'd13,11'd62,11'd112,11'd251};
                // K22: provisional response trim; preserve medium/soft anchors.
                // Reserve 127 for same-frame contacts rather than <=2 frames.
                21: key_velocity_limits={11'd0,11'd3,11'd5,11'd12};
                22: key_velocity_limits={11'd48,11'd99,11'd151,11'd426};
                23: key_velocity_limits={11'd26,11'd59,11'd93,11'd222};
                default: key_velocity_limits={11'd0,11'd0,11'd0,11'd0};
            endcase
        end
    endfunction

    // Reference only. Hardware shares one iterative divider across all keys.
    // Anchor medians stay per-key; medium strikes now map to 96 instead of 88.
    // synthesis translate_off
    function [7:0] travel_velocity;
        input integer key;
        input integer frames;
        reg [43:0] limits;
        integer hard_frame, medium_frame, soft_frame;
        begin
            limits=key_velocity_limits(key);
            hard_frame=limits[43:33];
            medium_frame=limits[21:11];
            soft_frame=2*limits[10:0]-medium_frame;
            if (frames <= hard_frame) travel_velocity=8'd127;
            else if (frames <= medium_frame)
                travel_velocity=127-((frames-hard_frame)*31+(medium_frame-hard_frame)/2)/
                    (medium_frame-hard_frame);
            else if (frames <= soft_frame)
                travel_velocity=96-((frames-medium_frame)*40+(soft_frame-medium_frame)/2)/
                    (soft_frame-medium_frame);
            else if (frames < 2*soft_frame)
                travel_velocity=56-((frames-soft_frame)*8+soft_frame/2)/soft_frame;
            else travel_velocity=8'd48;
        end
    endfunction
    // synthesis translate_on
    reg [15:0] strike_frames [0:23];
    reg [23:0] mapping_pending;
    reg [4:0] mapping_cursor, mapping_key, divide_bits;
    reg mapping_busy;
    reg [17:0] divide_quotient;
    reg [12:0] divide_remainder, divide_denominator;
    reg [7:0] mapping_base;
    wire [43:0] mapping_limits=key_velocity_limits(mapping_cursor);
    wire [12:0] hard_anchor={2'd0,mapping_limits[43:33]};
    wire [12:0] medium_anchor={2'd0,mapping_limits[21:11]};
    wire [12:0] soft_anchor=({2'd0,mapping_limits[10:0]}<<1)-medium_anchor;
    wire [15:0] mapping_frames=strike_frames[mapping_cursor];
    reg [12:0] segment_distance, segment_span;
    reg [7:0] segment_base;
    reg [5:0] segment_drop;
    always @* begin
        segment_distance=0;segment_span=1;segment_base=127;segment_drop=0;
        if(mapping_frames>hard_anchor && mapping_frames<=medium_anchor) begin
            segment_distance=mapping_frames[12:0]-hard_anchor;
            segment_span=medium_anchor-hard_anchor;
            segment_base=127;segment_drop=31;
        end else if(mapping_frames>medium_anchor && mapping_frames<=soft_anchor) begin
            segment_distance=mapping_frames[12:0]-medium_anchor;
            segment_span=soft_anchor-medium_anchor;
            segment_base=96;segment_drop=40;
        end else if(mapping_frames>soft_anchor && mapping_frames<2*soft_anchor) begin
            segment_distance=mapping_frames[12:0]-soft_anchor;
            segment_span=soft_anchor;
            segment_base=56;segment_drop=8;
        end else if(mapping_frames>hard_anchor) segment_base=48;
    end
    wire [18:0] segment_product=segment_distance*segment_drop;
    wire [18:0] rounded_numerator=segment_product+{6'd0,segment_span[12:1]};
    wire [13:0] division_trial={divide_remainder,divide_quotient[17]};
    wire division_subtract=division_trial>={1'b0,divide_denominator};
    wire [13:0] division_remainder=division_subtract ?
        division_trial-{1'b0,divide_denominator} : division_trial;
    wire [17:0] division_next={divide_quotient[16:0],division_subtract};
    assign measured_velocity = measured_valid ? strike_velocity[measured_key] : 8'd0;
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
            travel_started <= 0;
            measured_frames <= 0; measured_key <= 0; measured_valid <= 0;
            strike_measured <= 0;
            mapping_pending<=0;mapping_cursor<=0;mapping_key<=0;
            mapping_busy<=0;divide_bits<=0;divide_quotient<=0;
            divide_remainder<=0;divide_denominator<=1;mapping_base<=127;
            for (i=0;i<48;i=i+1) db_count[i] <= 0;
            for (i=0;i<24;i=i+1) begin
                ab_age[i] <= 0; pending_velocity[i] <= 0;
                strike_velocity[i] <= 127;strike_frames[i]<=0;
            end
        end else begin
            event_valid <= 0;
            if(mapping_busy) begin
                divide_quotient<=division_next;
                divide_remainder<=division_remainder[12:0];
                divide_bits<=divide_bits-1'b1;
                if(divide_bits==1) begin
                    strike_velocity[mapping_key]<=mapping_base-division_next[7:0];
                    mapping_pending[mapping_key]<=0;
                    mapping_busy<=0;
                end
            end else if(mapping_pending[mapping_cursor]) begin
                mapping_key<=mapping_cursor;
                mapping_base<=segment_base;
                divide_quotient<=rounded_numerator[17:0];
                divide_denominator<=segment_span;
                divide_remainder<=0;divide_bits<=18;mapping_busy<=1;
            end else mapping_cursor<=mapping_cursor==5'd23 ?
                5'd0 : mapping_cursor+5'd1;

            // Pace events to the audio consumer's one-event-per-sample rate.
            if (event_wait != 0) event_wait <= event_wait - 1'b1;
            if (event_cursor == 6'd23) event_cursor <= 0;
            else event_cursor <= event_cursor + 1'b1;
            if (!scan_valid && event_wait == 0 && pending_on[event_cursor[4:0]] &&
                !mapping_pending[event_cursor[4:0]]) begin
                event_wait <= EVENT_INTERVAL_CYCLES-1;
                event_valid <= 1;
                event_type <= `EVENT_NOTE_ON;
                key_id <= event_cursor[4:0];
                velocity <= strike_velocity[event_cursor[4:0]];
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
                    else if (db_count[i] >= ((contact_raw[i] ? DEBOUNCE_FRAMES : RELEASE_DEBOUNCE_FRAMES)-1)) begin
                        stable_contacts[i] <= contact_raw[i];
                        db_count[i] <= 0;
                    end else db_count[i] <= db_count[i] + 1'b1;
                end

                // Include a contact's debounced transition in this frame.
                for (k=0;k<24;k=k+1) begin
                    row_a=(k/6)*2; row_b=row_a+1; col=k%6;
                    // Capture first raw closures. Bounce does not restart timing;
                    // the stable contacts below still qualify the actual note.
                    if (!key_state[k] && !strike_measured[k]) begin
                        if (!travel_started[k] && contact_raw[row_a*6+col]) begin
                            travel_started[k] <= 1;
                            ab_age[k] <= 1;
                            if (contact_raw[row_b*6+col]) begin
                                measured_frames <= 0; measured_key <= k; measured_valid <= 1;
                                strike_measured[k] <= 1;
                                strike_frames[k] <= 0; mapping_pending[k]<=1;
                            end
                        end else if (travel_started[k]) begin
                            if (contact_raw[row_b*6+col]) begin
                                measured_frames <= ab_age[k]; measured_key <= k; measured_valid <= 1;
                                strike_measured[k] <= 1;
                                strike_frames[k] <= ab_age[k]; mapping_pending[k]<=1;
                            end else if (ab_age[k] < AB_MAX_FRAMES)
                                ab_age[k] <= ab_age[k] + 1'b1;
                        end
                    end
                    a_next = (contact_raw[row_a*6+col] != stable_contacts[row_a*6+col] &&
                              db_count[row_a*6+col] >= ((contact_raw[row_a*6+col] ? DEBOUNCE_FRAMES : RELEASE_DEBOUNCE_FRAMES)-1)) ?
                              contact_raw[row_a*6+col] : stable_contacts[row_a*6+col];
                    b_next = (contact_raw[row_b*6+col] != stable_contacts[row_b*6+col] &&
                              db_count[row_b*6+col] >= ((contact_raw[row_b*6+col] ? DEBOUNCE_FRAMES : RELEASE_DEBOUNCE_FRAMES)-1)) ?
                              contact_raw[row_b*6+col] : stable_contacts[row_b*6+col];
                    if (b_next && a_next && !key_state[k] && strike_measured[k]) begin
                        pending_on[k] <= 1;
                        key_state[k] <= 1;
                        pending_velocity[k] <= strike_velocity[k];
                        ab_age[k] <= 0;
                    end
                    if (!a_next && !b_next) begin
                        if (key_state[k]) begin
                            pending_off[k] <= 1;
                            key_state[k] <= 0;
                            travel_started[k] <= 0;
                            strike_measured[k] <= 0;
                            ab_age[k] <= 0;
                        end
                        // Wait for a qualified full release before rearming.
                        if (!contact_raw[row_a*6+col] && !contact_raw[row_b*6+col] &&
                            db_count[row_a*6+col] == 0 && db_count[row_b*6+col] == 0) begin
                            travel_started[k] <= 0;
                            strike_measured[k] <= 0;
                            ab_age[k] <= 0;
                        end
                    end
                end
            end
        end
    end
endmodule

`include "event_defs.vh"
// One memory writer per state, with reset validity masks.
// Allocator NOTE_ON must precede the tail scan, as in the canonical core.
module pitch_expression_bank #(
    parameter integer VOICES=32,
    parameter integer START_CLOCK=112,
    parameter integer STATIC_BASE_PITCH=0,
    parameter integer BOUNDED_PERIOD=0,
    parameter integer SYNC_LOOKUP=0
) (
    input wire clk,rst_n,sample_tick,
    input wire param_valid,
    input wire [3:0] param_id,
    input wire [15:0] param_value,
    input wire [VOICES-1:0] note_on,
    input wire [VOICES-1:0] key_down,
    input wire [VOICES*7-1:0] notes,
    input wire [VOICES*32-1:0] base_fcs,
    input wire [VOICES*48-1:0] base_periods,
    output wire [VOICES*32-1:0] fcs,
    output wire [VOICES*48-1:0] periods,
    output wire busy
);
    localparam integer INDEX_BITS=VOICES>1 ? $clog2(VOICES) : 1;
    // Core note_to_period max is 384760985 and reciprocal <= 65536.
    // The reduced state is valid only when NOTE_ON base periods fit 29 bits.
    localparam integer PERIOD_BITS=BOUNDED_PERIOD ? 29 : 48;
    reg signed [15:0] bend_target,bend;
    wire signed [23:0] vibrato_pitch;
    pitch_vibrato u_vibrato(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .param_valid(param_valid),.param_id(param_id),.param_value(param_value),
        .pitch_offset(vibrato_pitch)
    );
    reg [15:0] glide_samples;
    reg signed [23:0] pitch [0:VOICES-1];
    reg [6:0] goal [0:VOICES-1];
    reg signed [23:0] slope [0:VOICES-1];
    reg [15:0] remaining [0:VOICES-1];
    reg [15:0] duration [0:VOICES-1];
    reg [15:0] residue [0:VOICES-1];
    reg [15:0] error [0:VOICES-1];
    reg descending [0:VOICES-1];
    reg [31:0] result_fc [0:VOICES-1];
    reg [PERIOD_BITS-1:0] result_period [0:VOICES-1];
    reg initialized [0:VOICES-1];
    // A permutation of slot ranks: 0 is the most recent NOTE_ON. Release
    // tails retain their pitch but cannot become a legato glide source.
    reg [INDEX_BITS-1:0] recency [0:VOICES-1];
    reg [VOICES-1:0] new_this_frame;
    reg [8:0] cycle;
    reg scanning;
    reg [INDEX_BITS-1:0] slot;
    reg [1:0] step;
    reg [31:0] saved_fc;
    reg [PERIOD_BITS-1:0] saved_period;
    reg [16:0] saved_ratio,saved_reciprocal;
    localparam integer MULTIPLIER_BITS=BOUNDED_PERIOD ? 32 : 48;
    wire [MULTIPLIER_BITS-1:0] multiplier_input=step==2 ? saved_fc : saved_period;
    wire [16:0] multiplier_coefficient=step==2 ? saved_ratio : saved_reciprocal;
    wire [64:0] product=multiplier_input*multiplier_coefficient;
    reg signed [24:0] selected_pitch;
    reg [6:0] lookup_note;
    reg [7:0] lookup_fraction;
    wire [31:0] lookup_fc;
    wire [47:0] lookup_period;
    wire [16:0] ratio,reciprocal;
    generate if(SYNC_LOOKUP) begin : synchronous_lookup
        pitch_lookup_sync tables(.clk(clk),.note_id(lookup_note),
            .fraction(lookup_fraction),.fc(lookup_fc),.period_q16(lookup_period),
            .ratio(ratio),.reciprocal(reciprocal));
    end else begin : asynchronous_lookup
        note_to_fc frequency(.note_id(lookup_note),.fc(lookup_fc));
        note_to_period period(.note_id(lookup_note),.period_q16(lookup_period));
        pitch_fraction_rom fractions(.fraction(lookup_fraction),
            .ratio(ratio),.reciprocal(reciprocal));
    end endgenerate
    reg dividing,negative;
    reg [INDEX_BITS-1:0] divide_slot;
    reg [15:0] divisor;
    reg [23:0] quotient;
    reg [16:0] remainder;
    reg [4:0] bits_left;
    wire [17:0] shifted_remainder={remainder,quotient[23]};
    wire take_bit=shifted_remainder>={2'b0,divisor};
    wire [23:0] next_quotient={quotient[22:0],take_bit};
    wire [17:0] next_remainder_wide=take_bit ?
        shifted_remainder-{2'b0,divisor} : shifted_remainder;
    wire [16:0] next_remainder=next_remainder_wide[16:0];
    function [INDEX_BITS-1:0] start_index;
        input [VOICES-1:0] mask;
        integer k;
        begin
            start_index=0;
            for(k=0;k<VOICES;k=k+1)
                if(mask[k]) start_index=k;
        end
    endfunction
    wire starting=|note_on;
    wire [INDEX_BITS-1:0] start_slot=start_index(note_on);
    wire [6:0] triggered_note=notes[start_slot*7+:7];
    // The allocator already includes the incoming key in key_down. Exclude
    // NOTE_ON slots so a first key (or a same-slot retrigger) cannot glide
    // from its own old release tail. The core accepts one event per frame.
    localparam integer SOURCE_LEAVES=2**$clog2(VOICES);
    wire [2*SOURCE_LEAVES-1:1] source_valid;
    wire [INDEX_BITS-1:0] source_rank [1:2*SOURCE_LEAVES-1];
    wire [INDEX_BITS-1:0] source_index [1:2*SOURCE_LEAVES-1];
    genvar candidate,node;
    generate for(candidate=0;candidate<SOURCE_LEAVES;candidate=candidate+1) begin : source_candidates
        if(candidate<VOICES) begin : real_slot
            assign source_valid[SOURCE_LEAVES+candidate]=
                initialized[candidate] && key_down[candidate] && !note_on[candidate];
            assign source_rank[SOURCE_LEAVES+candidate]=recency[candidate];
            assign source_index[SOURCE_LEAVES+candidate]=candidate;
        end else begin : padding
            assign source_valid[SOURCE_LEAVES+candidate]=1'b0;
            assign source_rank[SOURCE_LEAVES+candidate]=0;
            assign source_index[SOURCE_LEAVES+candidate]=0;
        end
    end
    for(node=1;node<SOURCE_LEAVES;node=node+1) begin : source_selection
        wire choose_left=source_valid[2*node] &&
            (!source_valid[2*node+1] || source_rank[2*node]<source_rank[2*node+1]);
        assign source_valid[node]=source_valid[2*node] || source_valid[2*node+1];
        assign source_rank[node]=choose_left ? source_rank[2*node] : source_rank[2*node+1];
        assign source_index[node]=choose_left ? source_index[2*node] : source_index[2*node+1];
    end endgenerate
    wire start_glide=source_valid[1] && glide_samples!=0;
    wire [INDEX_BITS-1:0] source_slot=source_index[1];
    // pitch excludes global bend/vibrato: chained legato continues from the
    // current sliding pitch, without adding those offsets a second time.
    wire signed [23:0] source_pitch=pitch[source_slot];
    wire [31:0] source_fc=result_fc[source_slot];
    wire [PERIOD_BITS-1:0] source_period=result_period[source_slot];
    wire signed [23:0] delta=$signed({1'b0,triggered_note,16'b0})-
        source_pitch;
    wire [16:0] error_sum={1'b0,error[slot]}+{1'b0,residue[slot]};
    wire carry_error=error_sum>={1'b0,duration[slot]};
    wire signed [23:0] goal_pitch={1'b0,goal[slot],16'b0};
    reg signed [23:0] advanced_pitch;
    always @* begin
        advanced_pitch=0;
        if(initialized[slot]) begin
            advanced_pitch=pitch[slot];
            if(!new_this_frame[slot]) begin
                if(glide_samples==0 || remaining[slot]<=1)
                    advanced_pitch=goal_pitch;
                else if(remaining[slot]!=0)
                    advanced_pitch=pitch[slot]+slope[slot]+
                        (carry_error ? (descending[slot] ? -24'sd1 : 24'sd1) : 24'sd0);
            end
        end
        selected_pitch=$signed(advanced_pitch)+
            ($signed({{9{bend[15]}},bend}) <<< 4)+
            $signed({vibrato_pitch[23],vibrato_pitch});
        if(selected_pitch<0) begin lookup_note=0;lookup_fraction=0;end
        else if(selected_pitch>25'sd8323072) begin
            lookup_note=127;lookup_fraction=0;
        end else begin
            lookup_note=selected_pitch[22:16];
            lookup_fraction=selected_pitch[15:8];
        end
    end
    wire advance=scanning && step==3 && initialized[slot] &&
        !new_this_frame[slot] && !note_on[slot];
    wire [INDEX_BITS-1:0] state_write_slot=starting ? start_slot : slot;
    wire signed [23:0] state_write_pitch=starting ?
        (start_glide ? source_pitch : {1'b0,triggered_note,16'b0}) : advanced_pitch;
    wire [15:0] state_write_remaining=starting ?
        (start_glide ? glide_samples : 16'd0) :
        (glide_samples==0 || remaining[slot]<=1 ? 16'd0 : remaining[slot]-1'b1);
    wire [16:0] state_write_error_wide=starting ? 17'd0 :
        (glide_samples!=0 && remaining[slot]>1 ?
            (carry_error ? error_sum-duration[slot] : error_sum) : error[slot]);
    wire [15:0] state_write_error=state_write_error_wide[15:0];
    wire finish_division=dividing && bits_left==1;
    wire [INDEX_BITS-1:0] slope_write_slot=starting ? start_slot : divide_slot;
    wire signed [23:0] slope_write_value=starting ? 24'sd0 :
        (negative ? -$signed(next_quotient) : $signed(next_quotient));
    wire [15:0] residue_write_value=starting ? 16'd0 : next_remainder[15:0];
    // These arrays intentionally have no reset. Invalid entries cannot affect
    // pitch outputs or arithmetic; NOTE_ON writes all fields before use.
    always @(posedge clk) if(rst_n) begin
        if(starting) begin
            goal[start_slot]<=triggered_note;
            duration[start_slot]<=glide_samples==0 ? 16'd1 : glide_samples;
            descending[start_slot]<=start_glide && delta<0;
        end
        if(starting || advance) begin
            pitch[state_write_slot]<=state_write_pitch;
            remaining[state_write_slot]<=state_write_remaining;
            error[state_write_slot]<=state_write_error;
        end
        if(starting || finish_division) begin
            slope[slope_write_slot]<=slope_write_value;
            residue[slope_write_slot]<=residue_write_value;
        end
    end
    assign busy=scanning || dividing;
    genvar v;
    generate for(v=0;v<VOICES;v=v+1) begin : outputs
        assign fcs[v*32+:32]=note_on[v] ?
            (start_glide ? source_fc : base_fcs[v*32+:32]) :
            STATIC_BASE_PITCH || initialized[v] ? result_fc[v] : base_fcs[v*32+:32];
        assign periods[v*48+:48]=note_on[v] ?
            (start_glide ? source_period : base_periods[v*48+:48]) :
            STATIC_BASE_PITCH || initialized[v] ? result_period[v] : base_periods[v*48+:48];
    end endgenerate
    integer j;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            bend_target<=0;bend<=0;glide_samples<=0;
            cycle<=0;scanning<=0;slot<=0;step<=0;new_this_frame<=0;
            saved_fc<=0;saved_period<=0;saved_ratio<=65536;saved_reciprocal<=65536;
            dividing<=0;negative<=0;divide_slot<=0;divisor<=1;
            quotient<=0;remainder<=0;bits_left<=0;
            for(j=0;j<VOICES;j=j+1) begin
                result_fc[j]<=STATIC_BASE_PITCH ? 32'd731558 : 32'd0;
                result_period[j]<=STATIC_BASE_PITCH ? 48'd384760985 : 48'd0;
                initialized[j]<=0;
                recency[j]<=j;
            end
        end else begin
            new_this_frame<=sample_tick ? note_on : new_this_frame|note_on;
            if(param_valid && param_id==`PARAM_PITCH_BEND)
                bend_target <= $signed(param_value)<-8192 ? -16'sd8192 :
                    $signed(param_value)>8191 ? 16'sd8191 : $signed(param_value);
            if(param_valid && param_id==`PARAM_GLIDE) glide_samples<=param_value;
            if(sample_tick) begin
                cycle<=1;
                if(bend<bend_target)
                    bend<=($signed({bend_target[15],bend_target})-
                           $signed({bend[15],bend}))>64 ? bend+16'sd64 : bend_target;
                else if(bend>bend_target)
                    bend<=($signed({bend[15],bend})-
                           $signed({bend_target[15],bend_target}))>64 ? bend-16'sd64 : bend_target;
            end else if(cycle!=0)
                cycle<=cycle==START_CLOCK ? 9'd0 : cycle+9'd1;
            if(cycle==START_CLOCK) begin scanning<=1;slot<=0;step<=0;end
            else if(scanning) begin
                step<=step+1'b1;
                case(step)
                    0,1: if(step==(SYNC_LOOKUP ? 1 : 0)) begin
                        saved_fc<=lookup_fc;
                        saved_period<=lookup_period[PERIOD_BITS-1:0];
                        saved_ratio<=ratio;saved_reciprocal<=reciprocal;
                    end
                    2: if(!STATIC_BASE_PITCH || initialized[slot])
                        result_fc[slot]<=product[47:16];
                    3: begin
                        if(!STATIC_BASE_PITCH || initialized[slot])
                            result_period[slot]<=product[PERIOD_BITS+15:16];
                        if(slot==VOICES-1) scanning<=0;
                        else slot<=slot+1'b1;
                    end
                    default: ;
                endcase
            end
            if(dividing) begin
                quotient<=next_quotient;remainder<=next_remainder;
                bits_left<=bits_left-1'b1;
                if(bits_left==1) dividing<=0;
            end
            if(starting) begin
                for(j=0;j<VOICES;j=j+1) begin
                    if(j==start_slot) recency[j]<=0;
                    else if(recency[j]<recency[start_slot])
                        recency[j]<=recency[j]+1'b1;
                end
                if(start_glide) begin
                    dividing<=1;negative<=delta<0;divide_slot<=start_slot;
                    divisor<=glide_samples;
                    quotient<=delta<0 ? -delta : delta;
                    remainder<=0;bits_left<=24;
                end
            end
            for(j=0;j<VOICES;j=j+1) if(note_on[j]) begin
                initialized[j]<=1;
                result_fc[j]<=start_glide ? source_fc : base_fcs[j*32+:32];
                result_period[j]<=start_glide ? source_period : base_periods[j*48+:PERIOD_BITS];
            end
        end
    end
endmodule

// Global pitch vibrato: approximately 5 Hz at 48 kHz, maximum +/-50 cents.
// Depth changes slew over at most 256 samples; phase runs even at zero depth.
module pitch_vibrato (
    input wire clk,rst_n,sample_tick,param_valid,
    input wire [3:0] param_id,
    input wire [15:0] param_value,
    output reg signed [23:0] pitch_offset
);
    localparam [15:0] MODULATION_GATE = 16'd2048;
    reg [23:0] phase;
    reg [15:0] depth_target,depth;
    wire [15:0] magnitude=phase[22] ? ~phase[21:6] : phase[21:6];
    wire signed [16:0] triangle=phase[23] ?
        -$signed({1'b0,magnitude}) : $signed({1'b0,magnitude});
    wire signed [33:0] scaled=triangle*$signed({1'b0,depth});
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            phase<=0;depth_target<=0;depth<=0;pitch_offset<=0;
        end else begin
            if(param_valid && param_id==`PARAM_MODULATION)
                depth_target<=param_value < MODULATION_GATE ? 16'd0 :
                    param_value;
            if(sample_tick) begin
                phase<=phase+24'd1748;
                if(depth<depth_target)
                    depth<=({1'b0,depth_target}-{1'b0,depth})>17'd256 ?
                        depth+16'd256 : depth_target;
                else if(depth>depth_target)
                    depth<=({1'b0,depth}-{1'b0,depth_target})>17'd256 ?
                        depth-16'd256 : depth_target;
                pitch_offset<=(depth < MODULATION_GATE ? 34'sd0 : scaled) >>> 17;
            end
        end
    end
endmodule

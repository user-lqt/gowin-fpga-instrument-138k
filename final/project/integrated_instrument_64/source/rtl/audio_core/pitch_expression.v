`include "event_defs.vh"
// One memory writer per state, with reset validity masks.
// Allocator NOTE_ON must precede the tail scan, as in the canonical core.
// Shared control arithmetic updates separate per-voice glide/pitch states.
// Vibrato contributes a pitch offset to both frequency and string-period
// calculations; it is not an audio-amplitude modulation or a new voice.
module pitch_expression_bank #(
    parameter integer VOICES=32,
    parameter integer START_CLOCK=112,
    parameter integer STATIC_BASE_PITCH=0,
    parameter integer BOUNDED_PERIOD=0,
    parameter integer SYNC_LOOKUP=0,
    parameter integer DUAL_PITCH_PRODUCTS=0,
    parameter integer MASK_RESULT_RESET=0,
    parameter integer BANKED_RESULTS=0,
    parameter integer RESULT_BANK_LANES=16,
    parameter integer RESULT_READ_PORTS=5,
    parameter integer SYNC_GLIDE_STATE=BANKED_RESULTS,
    parameter integer SERIAL_RECENCY=BANKED_RESULTS
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
    output wire busy,
    input wire [((VOICES+RESULT_BANK_LANES-1)/RESULT_BANK_LANES)*RESULT_READ_PORTS*$clog2(RESULT_BANK_LANES)-1:0] result_read_slots,
    output wire [((VOICES+RESULT_BANK_LANES-1)/RESULT_BANK_LANES)*RESULT_READ_PORTS*80-1:0] result_read_values
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
    // Rank zero is the newest NOTE_ON; release tails cannot source legato.
    reg [INDEX_BITS-1:0] recency [0:VOICES-1];
    wire starting;
    wire [INDEX_BITS-1:0] start_slot;
    generate if(SERIAL_RECENCY) begin : serial_recency
        reg updating;
        reg [INDEX_BITS-1:0] update_slot,trigger_slot,old_rank;
        wire [INDEX_BITS-1:0] current_rank=recency[update_slot];
        wire [INDEX_BITS-1:0] next_rank=current_rank<old_rank ?
            current_rank+1'b1 : current_rank;
        integer rank_index;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                updating<=0;update_slot<=0;trigger_slot<=0;old_rank<=0;
                for(rank_index=0;rank_index<VOICES;rank_index=rank_index+1)
                    recency[rank_index]<=rank_index;
            end else if(starting) begin
                updating<=1;update_slot<=0;trigger_slot<=start_slot;
                old_rank<=recency[start_slot];
                recency[start_slot]<=0;
            end else if(updating) begin
                if(update_slot!=trigger_slot) recency[update_slot]<=next_rank;
                if(update_slot==VOICES-1) updating<=0;
                else update_slot<=update_slot+1'b1;
            end
        end
        // synthesis translate_off
        always @(posedge clk) if(rst_n && starting && updating)
            $fatal(1,"serial recency requires NOTE_ON spacing >= VOICES+1 clocks");
        // synthesis translate_on
    end else begin : parallel_recency
        integer rank_index;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                for(rank_index=0;rank_index<VOICES;rank_index=rank_index+1)
                    recency[rank_index]<=rank_index;
            end else if(starting) begin
                for(rank_index=0;rank_index<VOICES;rank_index=rank_index+1) begin
                    if(rank_index==start_slot) recency[rank_index]<=0;
                    else if(recency[rank_index]<recency[start_slot])
                        recency[rank_index]<=recency[rank_index]+1'b1;
                end
            end
        end
    end endgenerate
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
    wire [64:0] fast_fc_product;
    wire [64:0] fast_period_product;
    reg signed [24:0] selected_pitch;
    reg [6:0] lookup_note;
    reg [7:0] lookup_fraction;
    wire [31:0] lookup_fc;
    wire [47:0] lookup_period;
    wire [16:0] ratio,reciprocal;
    generate if(DUAL_PITCH_PRODUCTS) begin : parallel_products
        assign fast_fc_product=lookup_fc*ratio;
        assign fast_period_product=lookup_period[PERIOD_BITS-1:0]*reciprocal;
    end else begin : no_parallel_products
        assign fast_fc_product=0;
        assign fast_period_product=0;
    end endgenerate
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
    assign starting=|note_on;
    assign start_slot=start_index(note_on);
    wire [6:0] triggered_note=notes[start_slot*7+:7];
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
    wire signed [23:0] source_pitch=pitch[source_slot];
    wire [31:0] source_fc;
    wire [PERIOD_BITS-1:0] source_period;
    wire signed [23:0] delta=$signed({1'b0,triggered_note,16'b0})-
        source_pitch;
    wire [6:0] scan_goal;
    wire signed [23:0] scan_pitch,scan_slope;
    wire [15:0] scan_remaining,scan_duration,scan_residue,scan_error;
    wire scan_descending;
    wire [16:0] error_sum={1'b0,scan_error}+{1'b0,scan_residue};
    wire carry_error=error_sum>={1'b0,scan_duration};
    wire signed [23:0] goal_pitch={1'b0,scan_goal,16'b0};
    reg signed [23:0] advanced_pitch;
    always @* begin
        advanced_pitch=0;
        if(initialized[slot]) begin
            advanced_pitch=scan_pitch;
            if(!new_this_frame[slot]) begin
                if(glide_samples==0 || scan_remaining<=1)
                    advanced_pitch=goal_pitch;
                else if(scan_remaining!=0)
                    advanced_pitch=scan_pitch+scan_slope+
                        (carry_error ? (scan_descending ? -24'sd1 : 24'sd1) : 24'sd0);
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
    wire advance=scanning && step==(DUAL_PITCH_PRODUCTS ? 1 : 3) && initialized[slot] &&
        !new_this_frame[slot] && !note_on[slot];
    wire [INDEX_BITS-1:0] state_write_slot=starting ? start_slot : slot;
    wire signed [23:0] state_write_pitch=starting ?
        (start_glide ? source_pitch : {1'b0,triggered_note,16'b0}) : advanced_pitch;
    wire [15:0] state_write_remaining=starting ?
        (start_glide ? glide_samples : 16'd0) :
        (glide_samples==0 || scan_remaining<=1 ? 16'd0 : scan_remaining-1'b1);
    wire [16:0] state_write_error_wide=starting ? 17'd0 :
        (glide_samples!=0 && scan_remaining>1 ?
            (carry_error ? error_sum-scan_duration : error_sum) : scan_error);
    wire [15:0] state_write_error=state_write_error_wide[15:0];
    wire finish_division=dividing && bits_left==1;
    wire [INDEX_BITS-1:0] slope_write_slot=starting ? start_slot : divide_slot;
    wire signed [23:0] slope_write_value=starting ? 24'sd0 :
        (negative ? -$signed(next_quotient) : $signed(next_quotient));
    wire [15:0] residue_write_value=starting ? 16'd0 : next_remainder[15:0];
    // These arrays intentionally have no reset. Invalid entries cannot affect
    // pitch outputs or arithmetic; NOTE_ON writes all fields before use.
    generate if(SYNC_GLIDE_STATE) begin : prefetched_glide
        // Two-clock visits leave one edge for next-slot prefetch. Keep the
        // asynchronous pitch source separate for immediate legato NOTE_ON.
        wire [INDEX_BITS-1:0] read_slot=cycle==START_CLOCK ? {INDEX_BITS{1'b0}} :
            scanning && step==(DUAL_PITCH_PRODUCTS ? 1 : 3) ? slot+1'b1 : slot;
        reg [63:0] parameters_memory[0:VOICES-1]
            /* synthesis syn_ramstyle="block_ram" */;
        reg [31:0] progress_memory[0:VOICES-1]
            /* synthesis syn_ramstyle="block_ram" */;
        reg [63:0] read_parameters;
        reg [31:0] read_progress;
        reg signed [23:0] read_pitch;
        // Constant fields are latched by the existing serial divider. Its
        // final write packs all parameters, avoiding read-modify-write RAM.
        reg [6:0] divide_goal;
        reg [15:0] divide_duration;
        reg divide_descending;
        wire parameter_write=starting || finish_division;
        wire [63:0] parameter_value=starting ?
            {triggered_note,24'd0,glide_samples==0 ? 16'd1 : glide_samples,
                16'd0,start_glide && delta<0} :
            {divide_goal,slope_write_value,divide_duration,
                residue_write_value,divide_descending};
        wire [31:0] progress_value={state_write_remaining,state_write_error};
        always @(posedge clk) begin
            read_parameters<=parameters_memory[read_slot];
            read_progress<=progress_memory[read_slot];
            read_pitch<=pitch[read_slot];
            if(rst_n) begin
                if(parameter_write) begin
                    parameters_memory[slope_write_slot]<=parameter_value;
                    if(slope_write_slot==read_slot) read_parameters<=parameter_value;
                end
                if(starting || advance) begin
                    progress_memory[state_write_slot]<=progress_value;
                    pitch[state_write_slot]<=state_write_pitch;
                    if(state_write_slot==read_slot) begin
                        read_progress<=progress_value;
                        read_pitch<=state_write_pitch;
                    end
                end
                if(starting && start_glide) begin
                    divide_goal<=triggered_note;
                    divide_duration<=glide_samples==0 ? 16'd1 : glide_samples;
                    divide_descending<=start_glide && delta<0;
                end
            end
        end
        assign {scan_goal,scan_slope,scan_duration,scan_residue,scan_descending}=read_parameters;
        assign {scan_remaining,scan_error}=read_progress;
        assign scan_pitch=read_pitch;
    end else begin : asynchronous_glide
    assign scan_goal=goal[slot];
    assign scan_pitch=pitch[slot];
    assign scan_slope=slope[slot];
    assign scan_remaining=remaining[slot];
    assign scan_duration=duration[slot];
    assign scan_residue=residue[slot];
    assign scan_error=error[slot];
    assign scan_descending=descending[slot];
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
    end endgenerate
    assign busy=scanning || dividing;
    genvar v,b,r;
    generate if(BANKED_RESULTS) begin : banked_results
        localparam integer RB=$clog2(RESULT_BANK_LANES);
        localparam integer BANK_COUNT=(VOICES+RESULT_BANK_LANES-1)/RESULT_BANK_LANES;
        wire [BANK_COUNT*32-1:0] source_fcs;
        wire [BANK_COUNT*PERIOD_BITS-1:0] source_periods;
        assign source_fc=source_fcs[(source_slot/RESULT_BANK_LANES)*32+:32];
        assign source_period=source_periods[(source_slot/RESULT_BANK_LANES)*PERIOD_BITS+:PERIOD_BITS];
        wire scan_write=scanning && DUAL_PITCH_PRODUCTS && step==1 &&
            (!STATIC_BASE_PITCH || initialized[slot]);
        wire [INDEX_BITS-1:0] write_slot=starting ? start_slot : slot;
        wire [31:0] write_fc=starting ?
            (start_glide ? source_fc : base_fcs[start_slot*32+:32]) :
            fast_fc_product[47:16];
        wire [PERIOD_BITS-1:0] write_period=starting ?
            (start_glide ? source_period :
                base_periods[start_slot*48+:PERIOD_BITS]) :
            fast_period_product[PERIOD_BITS+15:16];
        // The allocator issues one NOTE_ON before the tail scan. Local RAM
        // readers replace the wide register fanout without adding latency.
        for(b=0;b<(VOICES+RESULT_BANK_LANES-1)/RESULT_BANK_LANES;b=b+1) begin : banks
            localparam integer BASE=b*RESULT_BANK_LANES;
            localparam integer COUNT=VOICES-BASE<RESULT_BANK_LANES ?
                VOICES-BASE : RESULT_BANK_LANES;
            reg [31:0] fc_memory[0:RESULT_BANK_LANES-1]
                /* synthesis syn_ramstyle="distributed_ram" */;
            reg [PERIOD_BITS-1:0] period_memory[0:RESULT_BANK_LANES-1]
                /* synthesis syn_ramstyle="distributed_ram" */;
            // Read stored results, never NOTE_ON bypass, to avoid feedback.
            assign source_fcs[b*32+:32]=fc_memory[source_slot[RB-1:0]];
            assign source_periods[b*PERIOD_BITS+:PERIOD_BITS]=
                period_memory[source_slot[RB-1:0]];
            always @(posedge clk) begin
                if(rst_n && (starting || scan_write) &&
                    write_slot/RESULT_BANK_LANES==b) begin
                    fc_memory[write_slot[RB-1:0]]<=write_fc;
                    period_memory[write_slot[RB-1:0]]<=write_period;
                end
            end
            for(r=0;r<RESULT_READ_PORTS;r=r+1) begin : readers
                wire [RB-1:0] address=result_read_slots[(b*RESULT_READ_PORTS+r)*RB+:RB];
                wire valid_entry=initialized[BASE+address];
                wire bypass=starting && start_slot/RESULT_BANK_LANES==b &&
                    start_slot[RB-1:0]==address;
                wire [31:0] fc_value=bypass ? write_fc : valid_entry ?
                    fc_memory[address] : (STATIC_BASE_PITCH ? 32'd731558 : 32'd0);
                wire [47:0] period_value=bypass ? {{(48-PERIOD_BITS){1'b0}},write_period} :
                    valid_entry ? {{(48-PERIOD_BITS){1'b0}},period_memory[address]} :
                    (STATIC_BASE_PITCH ? 48'd384760985 : 48'd0);
                assign result_read_values[(b*RESULT_READ_PORTS+r)*80+:80]=
                    {period_value,fc_value};
            end
            // Parallel observation ports are retained for verification. In the
            // banked core no synthesis consumer uses these memory-wide reads.
            for(v=0;v<COUNT;v=v+1) begin : observation
                wire bypass=note_on[BASE+v];
                assign fcs[(BASE+v)*32+:32]=bypass ? write_fc : initialized[BASE+v] ?
                    fc_memory[v] : (STATIC_BASE_PITCH ? 32'd731558 : 32'd0);
                assign periods[(BASE+v)*48+:48]=bypass ?
                    {{(48-PERIOD_BITS){1'b0}},write_period} : initialized[BASE+v] ?
                    {{(48-PERIOD_BITS){1'b0}},period_memory[v]} :
                    (STATIC_BASE_PITCH ? 48'd384760985 : 48'd0);
            end
        end
`ifndef SYNTHESIS
        // synthesis translate_off
        initial begin
            if(!DUAL_PITCH_PRODUCTS || !MASK_RESULT_RESET ||
                !STATIC_BASE_PITCH || VOICES%RESULT_BANK_LANES!=0 ||
                RESULT_BANK_LANES<2 ||
                (RESULT_BANK_LANES & (RESULT_BANK_LANES-1))!=0)
                $fatal(1,"unsupported banked pitch configuration");
        end
        always @(posedge clk) if(rst_n) begin
            if(starting && scan_write)
                $fatal(1,"banked pitch NOTE_ON must precede the result scan");
            if(starting && (note_on & (note_on-1'b1))!=0)
                $fatal(1,"banked pitch requires one-hot NOTE_ON");
        end
        // synthesis translate_on
`endif
    end else begin : parallel_results
    assign source_fc=result_fc[source_slot];
    assign source_period=result_period[source_slot];
    assign result_read_values=0;
    for(v=0;v<VOICES;v=v+1) begin : outputs
        wire [31:0] visible_fc=MASK_RESULT_RESET && !initialized[v] ?
            (STATIC_BASE_PITCH ? 32'd731558 : 32'd0) : result_fc[v];
        wire [PERIOD_BITS-1:0] visible_period=MASK_RESULT_RESET && !initialized[v] ?
            (STATIC_BASE_PITCH ? 48'd384760985 : 48'd0) : result_period[v];
        assign fcs[v*32+:32]=note_on[v] ?
            (start_glide ? source_fc : base_fcs[v*32+:32]) :
            STATIC_BASE_PITCH || initialized[v] ? visible_fc : base_fcs[v*32+:32];
        assign periods[v*48+:48]=note_on[v] ?
            (start_glide ? source_period : base_periods[v*48+:48]) :
            STATIC_BASE_PITCH || initialized[v] ? visible_period : base_periods[v*48+:48];
        if(MASK_RESULT_RESET) begin : valid_result
            // NOTE_ON precedes the next use. Only the existing valid bit resets.
            always @(posedge clk) if(rst_n) begin
                if(scanning && slot==v && (!STATIC_BASE_PITCH || initialized[v])) begin
                    if(DUAL_PITCH_PRODUCTS && step==1) begin
                        result_fc[v]<=fast_fc_product[47:16];
                        result_period[v]<=fast_period_product[PERIOD_BITS+15:16];
                    end else if(!DUAL_PITCH_PRODUCTS) begin
                        if(step==2) result_fc[v]<=product[47:16];
                        if(step==3) result_period[v]<=product[PERIOD_BITS+15:16];
                    end
                end
                if(note_on[v]) begin
                    result_fc[v]<=start_glide ? source_fc : base_fcs[v*32+:32];
                    result_period[v]<=start_glide ? source_period :
                        base_periods[v*48+:PERIOD_BITS];
                end
            end
        end else begin : reset_result
            always @(posedge clk or negedge rst_n) begin
                if(!rst_n) begin
                    result_fc[v]<=STATIC_BASE_PITCH ? 32'd731558 : 32'd0;
                    result_period[v]<=STATIC_BASE_PITCH ? 48'd384760985 : 48'd0;
                end else begin
                    if(scanning && slot==v && (!STATIC_BASE_PITCH || initialized[v])) begin
                        if(DUAL_PITCH_PRODUCTS && step==1) begin
                            result_fc[v]<=fast_fc_product[47:16];
                            result_period[v]<=fast_period_product[PERIOD_BITS+15:16];
                        end else if(!DUAL_PITCH_PRODUCTS) begin
                            if(step==2) result_fc[v]<=product[47:16];
                            if(step==3) result_period[v]<=product[PERIOD_BITS+15:16];
                        end
                    end
                    if(note_on[v]) begin
                        result_fc[v]<=start_glide ? source_fc : base_fcs[v*32+:32];
                        result_period[v]<=start_glide ? source_period :
                            base_periods[v*48+:PERIOD_BITS];
                    end
                end
            end
        end
    end
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
                initialized[j]<=0;
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
                step<=DUAL_PITCH_PRODUCTS ? (step==0 ? 1 : 0) : step+1'b1;
                if(DUAL_PITCH_PRODUCTS) begin
                    // Step 0 gives synchronous lookup ROMs a full clock.
                    // Step 1 commits both pitch products before moving slots.
                    if(step==1) begin
                        if(slot==VOICES-1) scanning<=0;
                        else slot<=slot+1'b1;
                    end
                end else begin
                case(step)
                    0,1: if(step==(SYNC_LOOKUP ? 1 : 0)) begin
                        saved_fc<=lookup_fc;
                        saved_period<=lookup_period[PERIOD_BITS-1:0];
                        saved_ratio<=ratio;saved_reciprocal<=reciprocal;
                    end
                    2: ;
                    3: begin
                        if(slot==VOICES-1) scanning<=0;
                        else slot<=slot+1'b1;
                    end
                    default: ;
                endcase
                end
            end
            if(dividing) begin
                quotient<=next_quotient;remainder<=next_remainder;
                bits_left<=bits_left-1'b1;
                if(bits_left==1) dividing<=0;
            end
            if(starting) begin
                if(start_glide) begin
                    dividing<=1;negative<=delta<0;divide_slot<=start_slot;
                    divisor<=glide_samples;
                    quotient<=delta<0 ? -delta : delta;
                    remainder<=0;bits_left<=24;
                end
            end
            for(j=0;j<VOICES;j=j+1) if(note_on[j]) begin
                initialized[j]<=1;
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

module mixer #(
    parameter integer VOICES = 4,
    parameter integer SAMPLE_BITS = 24
) (
    input  wire [VOICES*SAMPLE_BITS-1:0] voice_samples,
    input  wire [15:0]        volume,
    output wire signed [23:0] audio,
    output wire               overload_flag
);
    reg signed [31:0] sum;
    integer i;

    always @(*) begin
        sum = 32'sd0;
        for (i = 0; i < VOICES; i = i + 1)
            sum = sum + $signed(voice_samples[i*SAMPLE_BITS +: SAMPLE_BITS]);
    end

    wire signed [48:0] scaled =
        (sum * $signed({1'b0, volume})) >>> 16;

    assign overload_flag = (scaled > 45'sd8388607) ||
                           (scaled < -45'sd8388608);
    assign audio = scaled > 45'sd8388607 ? 24'sh7fffff :
                   scaled < -45'sd8388608 ? 24'sh800000 : scaled[23:0];
endmodule

// Scan before oscillator outputs change and well before gain step 14.
// The tick snapshot preserves the original filter's envelope gating.
module piano_body_state_bank #(parameter integer LANES=16)(
    input wire clk,rst_n,sample_tick,
    input wire [LANES-1:0] note_on,piano_active,
    input wire [LANES*16-1:0] waves,
    input wire [(LANES>1 ? $clog2(LANES) : 1)-1:0] read_lane,
    output wire signed [15:0] selected_body
);
    localparam integer IB=LANES>1 ? $clog2(LANES) : 1;
    reg signed [15:0] memory[0:LANES-1]
        /* synthesis syn_ramstyle="distributed_ram" */;
    reg [LANES-1:0] valid,cancelled,snapshot_active;
    reg [IB-1:0] lane;
    reg scanning;
    wire signed [15:0] previous=valid[lane] ? memory[lane] : 16'sd0;
    wire signed [15:0] wave=waves[lane*16+:16];
    wire signed [16:0] difference=
        $signed({wave[15],wave})-$signed({previous[15],previous});
    wire signed [16:0] filtered=
        $signed({previous[15],previous})+(difference >>> 5);
    wire allowed=snapshot_active[lane] && !cancelled[lane] && !note_on[lane];
    wire signed [15:0] next_body=allowed ? filtered[15:0] : 16'sd0;
    assign selected_body=valid[read_lane] ? memory[read_lane] : 16'sd0;
    always @(posedge clk)
        if(rst_n && scanning && !sample_tick) memory[lane]<=next_body;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            valid<=0;cancelled<=0;snapshot_active<=0;lane<=0;scanning<=0;
        end else begin
            valid<=valid & ~note_on;
            cancelled<=sample_tick ? note_on : cancelled|note_on;
            if(sample_tick) begin
                snapshot_active<=piano_active;lane<=0;scanning<=1;
            end else if(scanning) begin
                valid[lane]<=!cancelled[lane] && !note_on[lane];
                if(lane==LANES-1) scanning<=0;
                else lane<=lane+1'b1;
            end
        end
    end
endmodule

module voice_gain_bank #(
    parameter integer LANES=4,
    parameter integer VELOCITY_START=14,
    parameter integer LOCAL_SELECT=0,
    parameter integer RAM_VELOCITY=0,
    parameter integer RAM_HAMMER=0,
    parameter integer RAM_OUTPUT=0,
    parameter integer BANK_PIANO=0,
    parameter integer BANK_TIMBRE_GAIN=0,
    parameter integer DIRECT_INPUTS=0,
    parameter integer LOCAL_BODY=0,
    parameter integer LOCAL_PIANO=0,
    parameter integer LOCAL_STRIKE=0,
    parameter integer OUTPUT_BITS=24
) (
    input wire clk,rst_n,sample_tick,
    input wire [LANES*27-1:0] operands_a,
    input wire [LANES*18-1:0] operands_b,
    output wire [LANES*4-1:0] steps,
    output wire signed [44:0] product,
    output wire signed [33:0] hammer,
    input wire [(LANES>1 ? $clog2(LANES) : 1)-1:0] output_index,
    output wire signed [OUTPUT_BITS-1:0] output_sample,
    input wire [LANES*16-1:0] piano_bodies,
    input wire [LANES-1:0] piano_mask,
    input wire [LANES-1:0] guitar_mask,
    input wire [LANES-1:0] guitar_boost_mask,
    input wire [LANES*16-1:0] raw_waves,
    input wire [LANES*16-1:0] raw_noises,
    input wire [LANES*16-1:0] raw_strikes,
    input wire [LANES*8-1:0] raw_velocities,
    input wire [LANES*16-1:0] raw_envelopes,
    input wire signed [15:0] selected_body_wave,
    input wire signed [15:0] selected_piano_body,
    input wire [LANES-1:0] note_on,
    output wire [(LANES>1 ? $clog2(LANES) : 1)-1:0] input_lane
);
    localparam integer INDEX_BITS=LANES>1 ? $clog2(LANES) : 1;
    reg [7:0] cycle;
    reg [INDEX_BITS-1:0] lane;
    assign input_lane=lane;
    reg [3:0] operation;
    localparam [7:0] LANES_W=LANES;
    localparam [7:0] VELOCITY_START_W=VELOCITY_START;
    wire [7:0] lane0 = cycle - 8'd2;
    wire [7:0] lane1 = cycle - (8'd2 + LANES_W);
    wire [7:0] lane2 = cycle - VELOCITY_START_W;
    wire [7:0] lane3 = cycle - (VELOCITY_START_W + LANES_W);
    always @* begin
        lane=0; operation=0;
        if(cycle>=8'd2 && cycle<2+LANES) begin lane=lane0[INDEX_BITS-1:0]; operation=4'd2; end
        else if(cycle>=2+LANES && cycle<2+2*LANES) begin
            lane=lane1[INDEX_BITS-1:0]; operation=4'd3;
        end else if(cycle>=VELOCITY_START && cycle<VELOCITY_START+LANES) begin
            lane=lane2[INDEX_BITS-1:0]; operation=4'd14;
        end else if(cycle>=VELOCITY_START+LANES && cycle<VELOCITY_START+2*LANES) begin
            lane=lane3[INDEX_BITS-1:0]; operation=4'd15;
        end
    end
    wire signed [26:0] a;
    wire signed [17:0] b;
    wire [15:0] selected_strike,selected_noise;
    generate if(LOCAL_STRIKE) begin : strike_state
        // Canonical allocator publishes NOTE_ON immediately after the tick.
        // synthesis translate_off
        always @(posedge clk) if(rst_n && |note_on && !sample_tick && cycle!=1)
            $fatal(1,"local strike state requires tick-aligned allocator NOTE_ON");
        // synthesis translate_on
        reg [15:0] strike_memory[0:LANES-1]
            /* synthesis syn_ramstyle="distributed_ram" */;
        reg [15:0] noise_memory[0:LANES-1]
            /* synthesis syn_ramstyle="distributed_ram" */;
        reg [LANES-1:0] strike_valid,noise_valid,strike_pending,noise_pending;
        reg [LANES-1:0] tick_piano;
        wire [15:0] old_strike=strike_valid[lane] ? strike_memory[lane] : 16'd0;
        wire [15:0] old_noise=noise_valid[lane] ? noise_memory[lane] : 16'd1;
        wire [16:0] decrement=tick_piano[lane] ?
            (({1'b0,old_strike}+17'd1023)>>10) : 17'd8;
        wire [16:0] decreased={1'b0,old_strike}-decrement;
        assign selected_strike=strike_pending[lane] || note_on[lane] ? 16'hffff :
            (tick_piano[lane] ? old_strike>2 : old_strike>8) ?
                decreased[15:0] : 16'd0;
        assign selected_noise=noise_pending[lane] || note_on[lane] ? 16'd1 :
            {old_noise[14:0],old_noise[15]^old_noise[13]^old_noise[12]^old_noise[10]};
        always @(posedge clk) if(rst_n && !sample_tick) begin
            if(operation==2) strike_memory[lane]<=selected_strike;
            if(operation==3) noise_memory[lane]<=selected_noise;
        end
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                strike_valid<=0;noise_valid<=0;strike_pending<=0;noise_pending<=0;
                tick_piano<=0;
            end else begin
                strike_pending<=strike_pending|note_on;
                noise_pending<=noise_pending|note_on;
                if(sample_tick) tick_piano<=piano_mask;
                else begin
                    if(operation==2) begin
                        strike_valid[lane]<=1;strike_pending[lane]<=0;
                    end
                    if(operation==3) begin
                        noise_valid[lane]<=1;noise_pending[lane]<=0;
                    end
                end
            end
        end
    end else begin : parallel_strike_state
        assign selected_strike=raw_strikes[lane*16+:16];
        assign selected_noise=raw_noises[lane*16+:16];
    end endgenerate
    generate if(DIRECT_INPUTS) begin : direct_inputs
        wire [7:0] velocity=raw_velocities[lane*8+:8];
        wire [7:0] safe_velocity=velocity>127 ? 8'd127 : velocity;
        wire [15:0] strike=selected_strike;
        wire signed [15:0] noise=selected_noise;
        wire signed [15:0] wave=LOCAL_BODY && guitar_boost_mask[lane] ?
            selected_body_wave : raw_waves[lane*16+:16];
        assign a=operation==2 ? $signed({1'b0,safe_velocity}) :
            operation==3 ? noise : wave;
        assign b=operation==2 ? $signed({1'b0,strike[15:8]}) :
            operation==14 ? $signed({1'b0,safe_velocity}) :
            $signed({1'b0,raw_envelopes[lane*16+:16]});
    end else if(LOCAL_SELECT) begin : decoded_inputs
        reg [26:0] selected_a;
        reg [17:0] selected_b;
        integer k;
        always @* begin
            selected_a=0;selected_b=0;
            for(k=0;k<LANES;k=k+1) begin
                selected_a=selected_a | (operands_a[k*27+:27] & {27{lane==k}});
                selected_b=selected_b | (operands_b[k*18+:18] & {18{lane==k}});
            end
        end
        assign a=selected_a;
        assign b=selected_b;
    end else begin : indexed_inputs
        assign a=operands_a[lane*27+:27];
        assign b=operands_b[lane*18+:18];
    end endgenerate
    generate if(RAM_OUTPUT) begin : output_state
        reg signed [OUTPUT_BITS-1:0] memory[0:LANES-1] /* synthesis syn_ramstyle="distributed_ram" */;
        assign output_sample=memory[output_index];
        wire signed [OUTPUT_BITS-1:0] limited =
            product[44:OUTPUT_BITS+15]=={(30-OUTPUT_BITS){product[OUTPUT_BITS+15]}} ?
                product[OUTPUT_BITS+15:16] :
            product[44] ? {1'b1,{(OUTPUT_BITS-1){1'b0}}} :
                {1'b0,{(OUTPUT_BITS-1){1'b1}}};
        always @(posedge clk)
            if(rst_n && !sample_tick && operation==15) memory[lane]<=limited;
    end else begin : no_output_state
        assign output_sample=0;
    end endgenerate
    wire signed [26:0] multiply_a;
    wire signed [15:0] raw_wave=a[15:0];
    wire signed [19:0] guitar_boost=$signed(raw_wave) <<< 2;
    wire signed [15:0] boosted_wave=guitar_boost>20'sd32767 ? 16'sh7fff :
        guitar_boost< -20'sd32768 ? 16'sh8000 : guitar_boost[15:0];
    wire signed [15:0] selected_wave=BANK_TIMBRE_GAIN && guitar_boost_mask[lane] ?
        boosted_wave : raw_wave;
    wire [7:0] selected_strike_gain;
    strike_profile bank_strike_profile(.velocity(b[7:0]),
        .instrument(piano_mask[lane] ? 2'd0 : guitar_mask[lane] ? 2'd1 : 2'd2),
        .gain(selected_strike_gain));
    wire [15:0] bank_transient;
    generate if(BANK_TIMBRE_GAIN) begin : transient_state
        reg [15:0] memory[0:LANES-1] /* synthesis syn_ramstyle="distributed_ram" */;
        assign bank_transient=memory[lane];
        always @(posedge clk)
            if(rst_n && !sample_tick && operation==2) memory[lane]<=product[15:0];
    end else begin : no_transient_state
        assign bank_transient=0;
    end endgenerate
    wire signed [17:0] multiply_b=BANK_TIMBRE_GAIN && operation==14 ?
        $signed({1'b0,selected_strike_gain}) :
        BANK_TIMBRE_GAIN && operation==3 ? $signed({1'b0,bank_transient}) : b;
    wire signed [15:0] selected_body=LOCAL_PIANO ? selected_piano_body :
        piano_bodies[lane*16+:16];
    wire signed [17:0] body_scaled=$signed(selected_body) >>> 3;
    wire signed [33:0] hammer_shifted=hammer >>> 24;
    // The sliced hammer term makes the addition unsigned. Extend the wave
    // explicitly so negative half-cycles cannot become positive full scale.
    wire signed [17:0] excitation=$signed({{2{selected_wave[15]}},selected_wave})+
        (piano_mask[lane] ? body_scaled : 18'sd0)+
        (piano_mask[lane] ? hammer_shifted[17:0] : 18'sd0);
    wire signed [15:0] clipped_excitation=excitation>18'sd32767 ? 16'sh7fff :
        excitation< -18'sd32768 ? 16'sh8000 : excitation[15:0];
    wire signed [26:0] gain_a=BANK_PIANO && operation==14 ?
        {{11{clipped_excitation[15]}},clipped_excitation} : a;
    generate if(RAM_VELOCITY) begin : velocity_state
        reg signed [23:0] memory[0:LANES-1] /* synthesis syn_ramstyle="distributed_ram" */;
        // Every lane's step 14 precedes all step-15 reads, including after reset.
        assign multiply_a=operation==15 ? $signed({memory[lane],1'b0}) : gain_a;
        always @(posedge clk)
            if(rst_n && !sample_tick && operation==14) memory[lane]<=product[23:0];
    end else begin : private_velocity_state
        assign multiply_a=gain_a;
    end endgenerate
    assign product=multiply_a*multiply_b;
    generate if(RAM_HAMMER) begin : hammer_state
        reg signed [33:0] memory[0:LANES-1] /* synthesis syn_ramstyle="distributed_ram" */;
        assign hammer=memory[lane];
        always @(posedge clk)
            if(rst_n && !sample_tick && operation==3) memory[lane]<=product[33:0];
    end else begin : no_hammer_state
        assign hammer=0;
    end endgenerate
    genvar v;
    generate for(v=0;v<LANES;v=v+1) begin : lane_steps
        assign steps[v*4+:4]=lane==v ? operation : 4'd0;
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) cycle<=0;
        else if(sample_tick) cycle<=1;
        else if(cycle!=0) cycle<=cycle==VELOCITY_START-1+2*LANES ? 8'd0 : cycle+8'd1;
    end
endmodule

// A3: one signed adder per clock, followed by registered volume and saturation.
// Start at tick+15; the parent latches the result at tick+(VOICES+18).
// Consume one real voice sample per cycle, accumulating independent L/R sums.
// Normal note-based panning is bypassed by stereo_center during TEST, so both
// channels retain the same acceptance signal and voice-frequency inventory.
// Wide accumulation precedes master-volume multiplication and PCM24 saturation.
module mixer_serial #(
    parameter integer VOICES = 32,
    parameter integer BANKED_INPUT = 0,
    parameter integer BANK_LANES = 16,
    parameter integer SAMPLE_BITS = 24,
    parameter integer STEREO_OUTPUT = 0
) (
    input wire clk, rst_n, start,
    input wire [VOICES*SAMPLE_BITS-1:0] voice_samples,
    input wire [15:0] volume,
    output reg signed [23:0] audio,
    output reg overload_flag,
    input wire [((VOICES+BANK_LANES-1)/BANK_LANES)*SAMPLE_BITS-1:0] bank_samples,
    input wire [VOICES-1:0] voice_active,
    output wire [(VOICES>1 ? $clog2(VOICES) : 1)-1:0] sample_index,
    input wire stereo_center,
    input wire [VOICES*7-1:0] voice_notes,
    output reg signed [23:0] audio_right,
    output reg overload_right
);
    reg [1:0] state;
    localparam integer INDEX_BITS=VOICES>1 ? $clog2(VOICES) : 1;
    reg [INDEX_BITS-1:0] index;
    assign sample_index=index;
    localparam integer SUM_BITS = SAMPLE_BITS + $clog2(VOICES);
    localparam integer PRODUCT_BITS = SUM_BITS + 17;
    // Preserve full-scale sums for both 32- and 64-voice configurations.
    reg signed [SUM_BITS-1:0] sum;
    reg signed [PRODUCT_BITS-1:0] product;
    reg signed [SUM_BITS-1:0] sum_right;
    reg signed [PRODUCT_BITS-1:0] product_right;
    wire signed [PRODUCT_BITS-1:0] scaled = product >>> 16;
    wire signed [PRODUCT_BITS-1:0] scaled_right = product_right >>> 16;
    wire signed [SAMPLE_BITS-1:0] current_sample;
    // Pan before master gain while retaining the full PCM25 signed headroom.
    wire pan_enabled = STEREO_OUTPUT && !stereo_center;
    wire high_note = voice_notes[index*7+:7] >= 7'd72;
    wire signed [SAMPLE_BITS-1:0] left_sample = pan_enabled && high_note ?
        (current_sample >>> 1) : current_sample;
    wire signed [SAMPLE_BITS-1:0] right_sample = pan_enabled && !high_note ?
        (current_sample >>> 1) : current_sample;
    generate if(BANKED_INPUT) begin : banked_sample_select
        localparam integer BANKS=(VOICES+BANK_LANES-1)/BANK_LANES;
        reg [SAMPLE_BITS-1:0] selected;
        integer k;
        always @* begin
            selected=0;
            for(k=0;k<BANKS;k=k+1)
                selected=selected | (bank_samples[k*SAMPLE_BITS+:SAMPLE_BITS] &
                    {SAMPLE_BITS{index/BANK_LANES==k && voice_active[index]}});
        end
        assign current_sample=selected;
    end else if(VOICES>32) begin : local_sample_groups
        localparam integer GROUPS=(VOICES+7)/8;
        wire [GROUPS*SAMPLE_BITS-1:0] group_samples;
        genvar group;
        for(group=0;group<GROUPS;group=group+1) begin : groups
            localparam integer COUNT=VOICES-group*8<8 ? VOICES-group*8 : 8;
            mixer_sample_group #(.LANES(COUNT),.SAMPLE_BITS(SAMPLE_BITS)) u_select(
                .index(index[2:0]),.samples(voice_samples[group*8*SAMPLE_BITS+:COUNT*SAMPLE_BITS]),
                .selected(group_samples[group*SAMPLE_BITS+:SAMPLE_BITS]));
        end
        reg [SAMPLE_BITS-1:0] selected;
        integer k;
        always @* begin
            selected=0;
            for(k=0;k<GROUPS;k=k+1)
                selected=selected | (group_samples[k*SAMPLE_BITS+:SAMPLE_BITS] &
                    {SAMPLE_BITS{(index>>3)==k}});
        end
        assign current_sample=selected;
    end else begin : flat_sample_select
        reg [SAMPLE_BITS-1:0] selected;
        integer slot;
        always @* begin
            selected=0;
            for(slot=0;slot<VOICES;slot=slot+1)
                selected=selected | (voice_samples[slot*SAMPLE_BITS+:SAMPLE_BITS] &
                    {SAMPLE_BITS{index==slot}});
        end
        assign current_sample=selected;
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= 0;
            index <= 0;
            sum <= 0;
            product <= 0;
            sum_right <= 0;
            product_right <= 0;
            audio_right <= 0;
            overload_right <= 0;
            audio <= 0;
            overload_flag <= 0;
        end else if (start) begin
            state <= 1;
            index <= 0;
            sum <= 0;
            sum_right <= 0;
        end else case (state)
            1: begin
                sum <= sum + left_sample;
                sum_right <= sum_right + right_sample;
                if (index == VOICES-1) state <= 2;
                else index <= index + 1'b1;
            end
            2: begin
                product <= sum * $signed({1'b0, volume});
                product_right <= sum_right * $signed({1'b0, volume});
                state <= 3;
            end
            3: begin
                audio <= scaled > 46'sd8388607 ? 24'sh7fffff :
                         scaled < -46'sd8388608 ? 24'sh800000 : scaled[23:0];
                overload_flag <= scaled > 46'sd8388607 ||
                                 scaled < -46'sd8388608;
                audio_right <= scaled_right > 46'sd8388607 ? 24'sh7fffff :
                    scaled_right < -46'sd8388608 ? 24'sh800000 : scaled_right[23:0];
                overload_right <= scaled_right > 46'sd8388607 ||
                    scaled_right < -46'sd8388608;
                state <= 0;
            end
            default: ;
        endcase
    end
endmodule

module mixer_sample_group #(parameter integer LANES=8,parameter integer SAMPLE_BITS=24)(
    input wire [2:0] index,
    input wire [LANES*SAMPLE_BITS-1:0] samples,
    output reg [SAMPLE_BITS-1:0] selected
);
    integer k;
    always @* begin
        selected=0;
        for(k=0;k<LANES;k=k+1)
            selected=selected | (samples[k*SAMPLE_BITS+:SAMPLE_BITS] &
                {SAMPLE_BITS{index==k}});
    end
endmodule

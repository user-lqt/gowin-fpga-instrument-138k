// Karplus-Strong loop with fractional delay and a two-point loss filter.
// Candidate range: MIDI 24..127; lower notes use the existing oscillator.
module plucked_string #(
    parameter integer DYNAMIC_PITCH=0,
    parameter integer SHARE_ARITHMETIC=1
) (
    input wire clk, rst_n, sample_tick, note_on, enabled,
    input wire [31:0] fc,
    input wire [47:0] period_q16,
    input wire [7:0] velocity,
    output reg signed [15:0] wave
);
    reg signed [15:0] delay_line [0:2047];
    reg [10:0] pointer, fill_pointer;
    reg [11:0] length;
    reg [11:0] history;
    reg [15:0] fraction, noise, lag_noise;
    reg filling, running, warming;
    reg [11:0] warm_remaining;
    reg signed [16:0] prior_raw, prior_fractional;
    reg signed [16:0] dc;
    reg [31:0] fill_phase;
    reg signed [16:0] fill_noise, lag_prior, pick_prior;
    reg [15:0] pick_level;
    wire [47:0] corrected_period = period_q16 - 48'd32768;
    reg signed [15:0] ram_read;
    wire signed [16:0] raw = $signed(ram_read);
    wire signed [17:0] delta = prior_raw - raw;
    wire [11:0] requested_length=corrected_period[47:16]>2048 ? 12'd2048 :
        corrected_period[47:16]<2 ? 12'd2 : corrected_period[27:16];
    wire [11:0] live_length=requested_length>history ? history : requested_length;
    wire [15:0] live_fraction=DYNAMIC_PITCH ?
        (requested_length>history ? 16'd0 : corrected_period[15:0]) : fraction;
    wire signed [34:0] interpolation;
    wire signed [16:0] fractional_sample = raw + (interpolation >>> 16);
    wire signed [17:0] pair_sum =
        $signed({fractional_sample[16], fractional_sample}) +
        $signed({prior_fractional[16], prior_fractional});
    // Keep loop delay/phase independent of velocity; dynamics belongs to
    // excitation so a harder pluck does not change the tuning correction.
    wire signed [17:0] filtered = pair_sum >>> 1;
    wire signed [17:0] feedback = filtered - (filtered >>> 11);
    wire signed [16:0] noise_signed = $signed({noise[15], noise});
    wire signed [16:0] lag_signed = $signed({lag_noise[15], lag_noise});
    // Two correlated noise streams spaced by about 1/5 string period give
    // pluck-position notches instead of arbitrary strong periodic noise peaks.
    wire [15:0] position = fill_phase[31:16];
    wire [16:0] falling_numerator={16'hffff-position,1'b0};
    // floor(floor(n/3)/32) == floor(floor(n/32)/3).
    // Narrow the constant divider before replication across all string voices.
    wire [11:0] falling_quotient;
    wire signed [12:0] displacement_scaled = position < 16384 ?
        $signed({1'b0,position[15:4]}) - 13'sd512 :
        $signed({1'b0,falling_quotient}) - 13'sd512;
    wire signed [17:0] noise_pair = noise_signed + fill_noise;
    wire signed [17:0] lag_pair = lag_signed + lag_prior;
    wire signed [17:0] comb_noise = noise_pair - lag_pair;
    // Fill and playback are mutually exclusive: share the existing pick
    // multiplier for continuous velocity-dependent broadband excitation.
    wire signed [17:0] pick_difference = filling ? comb_noise :
        noise_signed - pick_prior;
    wire signed [34:0] pick_product;
    wire signed [18:0] dynamic_noise=pick_product >>> 19;
    wire signed [19:0] excitation = displacement_scaled + dynamic_noise;
    wire signed [18:0] output_sample =
        fractional_sample - dc + (pick_product >>> 22);
    wire [16:0] pick_loss_numerator={1'b0,pick_level}+17'd95;
    // floor(n/96) == floor(floor(n/32)/3), for nonnegative n.
    wire [11:0] pick_loss;
    wire [11:0] warm_quotient;
    generate if (SHARE_ARITHMETIC) begin : shared_math
        // Playback consumes interpolation only at the sample edge. Prepare the
        // pick product on idle clocks; fill still uses one product every clock.
        wire interpolate_now=sample_tick && !filling && !warming && running;
        wire signed [17:0] multiply_a=interpolate_now ? delta : pick_difference;
        wire signed [16:0] multiply_b=interpolate_now ?
            $signed({1'b0,live_fraction}) : $signed({1'b0,pick_level});
        wire signed [34:0] product=multiply_a*multiply_b;
        reg signed [34:0] prepared_pick;
        reg first_playback;
        // Fill may end one clock before the sample edge. The first pluck
        // still has nine zero gain bits, so its fallback is only 17 x 8.
        wire signed [24:0] initial_pick=
            noise_signed*$signed({1'b0,pick_level[15:9]});
        wire signed [34:0] initial_pick_scaled=
            $signed({{10{initial_pick[24]}},initial_pick}) <<< 9;
        always @(posedge clk or negedge rst_n)
            if (!rst_n) prepared_pick<=0;
            else if (!interpolate_now) prepared_pick<=product;
        always @(posedge clk or negedge rst_n)
            if (!rst_n) first_playback<=0;
            else if (note_on && enabled) first_playback<=1;
            else if (interpolate_now && enabled) first_playback<=0;
        assign interpolation=product;
        assign pick_product=filling ? product :
            first_playback ? initial_pick_scaled : prepared_pick;
        wire [11:0] divide_input=filling ? falling_numerator[16:5] :
            pick_loss_numerator[16:5];
        wire [11:0] quotient;
        string_constant_divide #(.DIVISOR(3)) divide_three(
            .numerator(divide_input),.quotient(quotient));
        string_constant_divide #(.DIVISOR(5)) divide_five(
            .numerator(corrected_period[27:16]),.quotient(warm_quotient));
        assign falling_quotient=quotient;
        assign pick_loss=quotient;
    end else begin : reference_math
        assign interpolation=delta*$signed({1'b0,live_fraction});
        assign pick_product=pick_difference*$signed({1'b0,pick_level});
        assign falling_quotient=falling_numerator[16:5] / 12'd3;
        assign pick_loss=pick_loss_numerator[16:5] / 12'd3;
        assign warm_quotient=corrected_period[27:16] / 12'd5;
    end endgenerate
    wire ram_write = rst_n && !(note_on && enabled) && !warming &&
        (filling || (sample_tick && enabled && running));
    wire [10:0] ram_address = filling ? fill_pointer : pointer;
    wire [10:0] read_address=DYNAMIC_PITCH ? pointer-live_length : pointer;
    wire signed [15:0] ram_data = filling ? excitation[15:0] : feedback[15:0];
    // Unreset synchronous RAM ports. Pointer changes only at a sample boundary;
    // the next read settles before the next tick, preserving loop samples.
    always @(posedge clk) begin
        ram_read <= delay_line[read_address];
        if (ram_write) delay_line[ram_address] <= ram_data;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wave <= 0; pointer <= 0; fill_pointer <= 0;
            length <= 2; fraction <= 0; filling <= 0; running <= 0;
            history<=2;
            warming <= 0; warm_remaining <= 0;
            noise <= 16'hace1; lag_noise <= 16'hace1;
            prior_raw <= 0; prior_fractional <= 0;
            dc <= 0; fill_phase <= 0;
            fill_noise <= 0; lag_prior <= 0; pick_prior <= 0; pick_level <= 0;
        end else if (note_on && enabled) begin
            length <= corrected_period[47:16] > 2048 ? 2048 :
                      corrected_period[47:16] < 2 ? 2 : corrected_period[27:16];
            fraction <= corrected_period[15:0];
            pointer <= DYNAMIC_PITCH ? requested_length[10:0] : 11'd0;
            history<=requested_length;
            fill_pointer <= 0; filling <= 1; running <= 1;
            warming <= 1;
            warm_remaining <= corrected_period[47:16] > 2048 ? 409 :
                corrected_period[47:16] < 10 ? 1 : warm_quotient;
            noise <= 16'hace1; lag_noise <= 16'hace1; wave <= 0;
            prior_raw <= 0; prior_fractional <= 0; dc <= 0; fill_phase <= 0;
            fill_noise <= 0; lag_prior <= 0; pick_prior <= 0;
            pick_level <= {(velocity>127 ? 7'd127 : velocity[6:0]),9'd0};
        end else if (warming) begin
            noise <= {noise[14:0], noise[15]^noise[13]^noise[12]^noise[10]};
            if (warm_remaining <= 1) warming <= 0;
            else warm_remaining <= warm_remaining - 1'b1;
        end else if (filling) begin
            noise <= {noise[14:0], noise[15]^noise[13]^noise[12]^noise[10]};
            lag_noise <= {lag_noise[14:0],
                lag_noise[15]^lag_noise[13]^lag_noise[12]^lag_noise[10]};
            fill_noise <= noise_signed;
            lag_prior <= lag_signed;
            fill_phase <= fill_phase + fc;
            if (fill_pointer == length - 1) filling <= 0;
            else fill_pointer <= fill_pointer + 1'b1;
        end else if (sample_tick && enabled && running) begin
            prior_raw <= raw;
            prior_fractional <= fractional_sample;
            pointer <= DYNAMIC_PITCH ? pointer+1'b1 :
                pointer == length - 1 ? 0 : pointer + 1'b1;
            if(DYNAMIC_PITCH && history<2048) history<=history+1'b1;
            dc <= dc + ((fractional_sample - dc) >>> 9);
            // A short nonperiodic pick transient, outside the feedback loop.
            noise <= {noise[14:0], noise[15]^noise[13]^noise[12]^noise[10]};
            pick_prior <= noise_signed;
            pick_level <= pick_level - pick_loss;
            wave <= output_sample > 32767 ? 16'sh7fff :
                    output_sample < -32768 ? 16'sh8000 : output_sample[15:0];
        end else if (!enabled) wave <= 0;
    end
endmodule

// Constant long division needs only ceil(log2(DIVISOR)) remainder bits,
// rather than a full-width subtraction at every quotient bit.
module string_constant_divide #(
    parameter integer WIDTH=12,
    parameter integer DIVISOR=3
) (
    input wire [WIDTH-1:0] numerator,
    output wire [WIDTH-1:0] quotient
);
    localparam integer REMAINDER_BITS=$clog2(DIVISOR);
    localparam [REMAINDER_BITS:0] DENOMINATOR=DIVISOR;
    wire [REMAINDER_BITS-1:0] remainder[0:WIDTH];
    assign remainder[0]=0;
    genvar bit_index;
    generate for(bit_index=0;bit_index<WIDTH;bit_index=bit_index+1) begin : digits
        wire [REMAINDER_BITS:0] trial={
            remainder[bit_index],numerator[WIDTH-1-bit_index]};
        wire [REMAINDER_BITS:0] reduced=trial-DENOMINATOR;
        assign quotient[WIDTH-1-bit_index]=trial>=DENOMINATOR;
        assign remainder[bit_index+1]=trial>=DENOMINATOR ?
            reduced[REMAINDER_BITS-1:0] : trial[REMAINDER_BITS-1:0];
    end endgenerate
endmodule

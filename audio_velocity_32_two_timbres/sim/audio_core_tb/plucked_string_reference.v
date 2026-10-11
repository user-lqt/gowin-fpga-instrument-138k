// Karplus-Strong loop with fractional delay and a two-point loss filter.
// Candidate range: MIDI 24..127; lower notes use the existing oscillator.
module plucked_string_reference #(
    parameter integer DYNAMIC_PITCH=0
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
    wire signed [34:0] interpolation = delta * $signed({1'b0, live_fraction});
    wire signed [16:0] fractional_sample = raw + (interpolation >>> 16);
    wire signed [17:0] pair_sum =
        $signed({fractional_sample[16], fractional_sample}) +
        $signed({prior_fractional[16], prior_fractional});
    // Velocity changes the loop's high-frequency loss, not only output gain.
    wire signed [17:0] filter_delta = prior_fractional - fractional_sample;
    wire signed [17:0] filtered = (pair_sum >>> 1) +
        (velocity > 90 ? -(filter_delta >>> 3) : 18'sd0);
    wire signed [17:0] feedback = filtered - (filtered >>> 11);
    wire signed [16:0] noise_signed = $signed({noise[15], noise});
    wire signed [16:0] lag_signed = $signed({lag_noise[15], lag_noise});
    // Two correlated noise streams spaced by about 1/5 string period give
    // pluck-position notches instead of arbitrary strong periodic noise peaks.
    wire [15:0] position = fill_phase[31:16];
    wire [16:0] falling_numerator={16'hffff-position,1'b0};
    wire [16:0] falling_quotient=falling_numerator / 17'd3;
    wire signed [31:0] displacement = position < 16384 ?
        $signed({1'b0, position}) * 32'sd2 - 32'sd16384 :
        $signed({1'b0,falling_quotient}) - 32'sd16384;
    wire signed [17:0] noise_pair = noise_signed + fill_noise;
    wire signed [17:0] lag_pair = lag_signed + lag_prior;
    wire signed [18:0] comb_noise = noise_pair - lag_pair;
    wire signed [31:0] excitation = (displacement >>> 5) +
        (velocity <= 32 ? (comb_noise >>> 4) : (comb_noise >>> 3));
    wire signed [17:0] pick_difference = noise_signed - pick_prior;
    wire signed [34:0] pick_product =
        pick_difference * $signed({1'b0, pick_level});
    wire signed [18:0] output_sample =
        fractional_sample - dc + (pick_product >>> 22);
    wire [16:0] pick_loss_numerator={1'b0,pick_level}+17'd95;
    // floor(n/96) == floor(floor(n/32)/3), for nonnegative n.
    wire [11:0] pick_loss=pick_loss_numerator[16:5] / 12'd3;
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
                corrected_period[47:16] < 10 ? 1 : corrected_period[27:16] / 5;
            noise <= 16'hace1; lag_noise <= 16'hace1; wave <= 0;
            prior_raw <= 0; prior_fractional <= 0; dc <= 0; fill_phase <= 0;
            fill_noise <= 0; lag_prior <= 0; pick_prior <= 0;
            pick_level <= velocity <= 32 ? 16'h7fff : velocity <= 90 ? 16'hbfff : 16'hffff;
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

// Fixed four-voice headroom is independent of the user volume control.
module mixer #(
    parameter integer HEADROOM_SHIFT = 2
) (
    input  wire [95:0]        voice_samples,
    input  wire [15:0]        volume,
    output wire signed [23:0] audio,
    output wire               overload_flag
);
    wire signed [27:0] sum =
        $signed({{4{voice_samples[23]}}, voice_samples[23:0]}) +
        $signed({{4{voice_samples[47]}}, voice_samples[47:24]}) +
        $signed({{4{voice_samples[71]}}, voice_samples[71:48]}) +
        $signed({{4{voice_samples[95]}}, voice_samples[95:72]});

    wire signed [44:0] scaled =
        (sum * $signed({1'b0, volume})) >>> (16 + HEADROOM_SHIFT);

    assign overload_flag = (scaled > 45'sd8388607) ||
                           (scaled < -45'sd8388608);
    assign audio = scaled > 45'sd8388607 ? 24'sh7fffff :
                   scaled < -45'sd8388608 ? 24'sh800000 : scaled[23:0];
endmodule

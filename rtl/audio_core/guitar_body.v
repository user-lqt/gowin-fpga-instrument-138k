// Broad body-colour filters, not a measured acoustic guitar impulse response.
module guitar_body (
    input wire clk, rst_n, sample_tick, note_on,
    input wire signed [15:0] string_wave,
    output wire signed [15:0] wave
);
    reg signed [23:0] x1, x2;
    reg signed [23:0] low1, low2, mid1, mid2, high1, high2, tone;
    wire signed [24:0] difference = $signed({string_wave[15], string_wave}) - x2;
    // Q20, 48 kHz: broad 180/650/1250-Hz bands. Upper bands retain
    // the attack's string texture rather than colouring only the fundamental.
    wire signed [63:0] low_sum =
        difference * 64'sd8171 + low1 * 64'sd2080233 - low2 * 64'sd1032235;
    wire signed [63:0] mid_sum =
        difference * 64'sd21814 + mid1 * 64'sd2046095 - mid2 * 64'sd1004948;
    wire signed [63:0] high_sum =
        difference * 64'sd33084 + high1 * 64'sd2003857 - high2 * 64'sd982408;
    wire signed [25:0] coloured =
        ($signed(string_wave) >>> 1) + low1 + mid1 + (high1 >>> 1);
    wire signed [26:0] tone_delta = coloured - tone;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x1 <= 0; x2 <= 0; low1 <= 0; low2 <= 0;
            mid1 <= 0; mid2 <= 0; high1 <= 0; high2 <= 0; tone <= 0;
        end else if (note_on) begin
            x1 <= 0; x2 <= 0; low1 <= 0; low2 <= 0;
            mid1 <= 0; mid2 <= 0; high1 <= 0; high2 <= 0; tone <= 0;
        end else if (sample_tick) begin
            x1 <= string_wave; x2 <= x1;
            low1 <= low_sum >>> 20; low2 <= low1;
            mid1 <= mid_sum >>> 20; mid2 <= mid1;
            high1 <= high_sum >>> 20; high2 <= high1;
            tone <= tone + (tone_delta >>> 1) + (tone_delta >>> 2);
        end
    end
    assign wave = tone > 32767 ? 16'sh7fff :
                  tone < -32768 ? 16'sh8000 : tone[15:0];
endmodule

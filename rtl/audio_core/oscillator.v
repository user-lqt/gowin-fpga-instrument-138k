// A1/A2 sine path and A3 additive synthesis share the original phase/ROM.
`include "event_defs.vh"
module oscillator #(
    parameter integer ENABLE_TIMBRES = 0
) (
    input wire clk, rst_n, sample_tick, phase_load,
    input wire [31:0] fc,
    input wire [1:0] instrument,
    input wire [7:0] brightness,
    output wire signed [15:0] wave
);
    wire [11:0] addr;
    wire [31:0] phase;
    phase_acc u_phase_acc (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .phase_load(phase_load), .fc(fc), .phase(phase), .addr(addr)
    );
    generate if (!ENABLE_TIMBRES) begin : legacy
        wavetable u_wavetable (.clk(clk), .addr(addr), .dout(wave));
    end else begin : timbres
        // One synchronous ROM per voice, reused for four harmonic reads.
        reg [3:0] cycle;
        reg [31:0] snapshot;
        reg [31:0] harmonic_phase;
        wire signed [15:0] lookup_wave;
        reg signed [17:0] fundamental, second, third, fifth;
        reg signed [17:0] body, upper;
        reg [31:0] piano_phase2, piano_phase3, piano_phase5;
        reg [31:0] piano_snapshot2, piano_snapshot3, piano_snapshot5;
        reg [7:0] piano_gain1, piano_gain2, piano_gain3, piano_gain5;
        wire signed [26:0] piano_h1 = fundamental * $signed({1'b0, piano_gain1});
        wire signed [26:0] piano_h2 = second * $signed({1'b0, piano_gain2});
        wire signed [26:0] piano_h3 = third * $signed({1'b0, piano_gain3});
        wire signed [26:0] piano_h5 = fifth * $signed({1'b0, piano_gain5});
        wire signed [28:0] piano_upper_sum =
            $signed({{2{piano_h2[26]}}, piano_h2}) +
            $signed({{2{piano_h3[26]}}, piano_h3}) +
            $signed({{2{piano_h5[26]}}, piano_h5});
        wire signed [28:0] piano_upper = piano_upper_sum >>> 8;
        wire signed [37:0] piano_bright = piano_upper * $signed({1'b0, brightness});
        wire signed [28:0] piano_result = (piano_h1 >>> 8) +
            piano_upper + (piano_bright >>> 8);
        reg [7:0] qudi_second, qudi_third, qudi_fifth;
        wire signed [24:0] qudi_h1 = fundamental * 8'sd80;
        wire signed [26:0] qudi_h2 = second * $signed({1'b0, qudi_second});
        wire signed [26:0] qudi_h3 = third * $signed({1'b0, qudi_third});
        wire signed [26:0] qudi_h5 = fifth * $signed({1'b0, qudi_fifth});
        wire signed [28:0] qudi_sum =
            {{4{qudi_h1[24]}}, qudi_h1} +
            {{2{qudi_h2[26]}}, qudi_h2} +
            {{2{qudi_h3[26]}}, qudi_h3} +
            {{2{qudi_h5[26]}}, qudi_h5};
        wire signed [26:0] bright_product =
            upper * $signed({1'b0, brightness});
        wire signed [17:0] result = instrument == 2 ? (qudi_sum >>> 8) :
            instrument == 0 ? piano_result :
                              body + (bright_product >>> 7);
        reg signed [15:0] output_wave;
        wavetable u_wavetable (
            .clk(clk), .addr(harmonic_phase[31:20]), .dout(lookup_wave)
        );
        always @(*) begin
            // Four-mode approximation of the supplied upright-piano spectra.
            // Coefficient sums leave room for velocity-dependent brightness.
            if (fc < 32'd12418159) begin
                piano_gain1 = 20; piano_gain2 = 104;
                piano_gain3 = 28; piano_gain5 = 20;
            end else if (fc < 32'd24836318) begin
                piano_gain1 = 64; piano_gain2 = 80;
                piano_gain3 = 36; piano_gain5 = 12;
            end else if (fc < 32'd49672636) begin
                piano_gain1 = 140; piano_gain2 = 38;
                piano_gain3 = 24; piano_gain5 = 5;
            end else begin
                piano_gain1 = 184; piano_gain2 = 20;
                piano_gain3 = 2; piano_gain5 = 0;
            end
            // Selected stable windows from the seven supplied recordings.
            // Fixed gain leaves headroom even for the second-rich E5.
            if (fc < 32'd41711627) begin
                qudi_second = 19; qudi_third = 47; qudi_fifth = 2;
            end else if (fc < 32'd46819719) begin
                qudi_second = 72; qudi_third = 30; qudi_fifth = 3;
            end else if (fc < 32'd52553357) begin
                qudi_second = 13; qudi_third = 7; qudi_fifth = 12;
            end else if (fc < 32'd55678342) begin
                qudi_second = 12; qudi_third = 34; qudi_fifth = 12;
            end else if (fc < 32'd62496826) begin
                qudi_second = 88; qudi_third = 17; qudi_fifth = 23;
            end else if (fc < 32'd70150316) begin
                qudi_second = 12; qudi_third = 22; qudi_fifth = 3;
            end else begin
                qudi_second = 12; qudi_third = 35; qudi_fifth = 31;
            end
            case (cycle)
                4, 5: harmonic_phase = instrument == 0 ?
                    piano_snapshot2 :
                    (snapshot << 1);
                6, 7: harmonic_phase = instrument == 0 ?
                    piano_snapshot3 :
                    (snapshot + (snapshot << 1));
                8, 9: harmonic_phase = instrument == 0 ?
                    piano_snapshot5 :
                    (snapshot + (snapshot << 2));
                default: harmonic_phase = snapshot;
            endcase
            case (instrument)
                3: begin
                    body = (fundamental >>> 1) + (second >>> 3);
                    upper = (second >>> 3) + (third >>> 2) + (fifth >>> 3);
                end
                1: begin
                    body = fundamental >>> 1;
                    upper = (second >>> 3) + (third >>> 2) + (fifth >>> 3);
                end
                2: begin
                    body = 0;
                    upper = 0;
                end
                default: begin
                    // Piano: strong fundamental, audible upper partials and a
                    // slight inharmonic stretch for the steel-string attack.
                    body = (fundamental >>> 1) + (fundamental >>> 3);
                    upper = (second >>> 1) + (third >>> 2) + (fifth >>> 3);
                end
            endcase
        end
        // Accumulate stretched frequencies; scaling an already wrapped phase
        // would introduce a discontinuity at every fundamental-period wrap.
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                piano_phase2 <= 0; piano_phase3 <= 0; piano_phase5 <= 0;
            end else if (phase_load) begin
                piano_phase2 <= 0; piano_phase3 <= 0; piano_phase5 <= 0;
            end else if (sample_tick) begin
                piano_phase2 <= piano_phase2 + (fc << 1) + (fc >> 11);
                piano_phase3 <= piano_phase3 + fc + (fc << 1) + (fc >> 9);
                piano_phase5 <= piano_phase5 + fc + (fc << 2) + (fc >> 7);
            end
        end
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                cycle <= 0;
                snapshot <= 0;
                piano_snapshot2 <= 0;
                piano_snapshot3 <= 0;
                piano_snapshot5 <= 0;
                fundamental <= 0;
                second <= 0;
                third <= 0;
                fifth <= 0;
                output_wave <= 0;
            end else if (sample_tick) begin
                cycle <= 1;
            end else if (cycle != 0) begin
                cycle <= cycle == 12 ? 0 : cycle + 1'b1;
                case (cycle)
                    // Phase reset from the allocator completes at clock 1.
                    2: begin
                        snapshot <= phase;
                        piano_snapshot2 <= piano_phase2;
                        piano_snapshot3 <= piano_phase3;
                        piano_snapshot5 <= piano_phase5;
                    end
                    4: fundamental <= lookup_wave;
                    6: second <= fc < 32'h40000000 ? lookup_wave : 16'sd0;
                    8: third <= fc < 32'h2aaaaaaa ? lookup_wave : 16'sd0;
                    10: fifth <= fc < 32'h19999999 ? lookup_wave : 16'sd0;
                    12: output_wave <= result > 32767 ? 16'sh7fff :
                                       result < -32768 ? 16'sh8000 : result[15:0];
                    default: ;
                endcase
            end
        end
        assign wave = output_wave;
    end endgenerate
endmodule

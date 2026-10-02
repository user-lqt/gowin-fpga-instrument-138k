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
        wire signed [26:0] bright_product =
            upper * $signed({1'b0, brightness});
        wire signed [17:0] result = body + (bright_product >>> 7);
        reg signed [15:0] output_wave;
        wavetable u_wavetable (
            .clk(clk), .addr(harmonic_phase[31:20]), .dout(lookup_wave)
        );
        always @(*) begin
            case (cycle)
                4, 5: harmonic_phase = snapshot << 1;
                6, 7: harmonic_phase = snapshot + (snapshot << 1);
                8, 9: harmonic_phase = snapshot + (snapshot << 2);
                default: harmonic_phase = snapshot;
            endcase
            case (instrument)
                1: begin
                    body = fundamental >>> 1;
                    upper = (second >>> 3) + (third >>> 2) + (fifth >>> 3);
                end
                2: begin
                    body = fundamental >>> 2;
                    upper = (second >>> 2) + (second >>> 3) +
                            (third >>> 2) + (fifth >>> 3);
                end
                default: begin
                    body = (fundamental >>> 1) + (fundamental >>> 2);
                    upper = (second >>> 3) + (third >>> 4) + (fifth >>> 4);
                end
            endcase
        end
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                cycle <= 0;
                snapshot <= 0;
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
                    2: snapshot <= phase;
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

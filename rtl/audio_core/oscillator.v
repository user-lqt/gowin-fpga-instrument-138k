// A1/A2 sine path and A3 additive synthesis share the original phase/ROM.
`include "event_defs.vh"
module oscillator #(
    parameter integer ENABLE_TIMBRES = 0,
    parameter integer SHARED_ARITHMETIC = 0,
    parameter integer BANK_LANES = 8,
    parameter integer BANK_LANE = 0
) (
    input wire clk, rst_n, sample_tick, phase_load,
    input wire [31:0] fc,
    input wire [1:0] instrument,
    input wire [7:0] brightness,
    input wire [6:0] bank_cycle,
    input wire signed [15:0] bank_lookup_wave,
    input wire signed [26:0] bank_product,
    output wire [11:0] bank_address,
    output wire signed [17:0] bank_operand,
    output wire [7:0] bank_gain,
    output wire signed [15:0] wave
);
    wire [11:0] addr;
    wire [31:0] phase;
    phase_acc u_phase_acc (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .phase_load(phase_load), .fc(fc), .phase(phase), .addr(addr)
    );
    generate if (!ENABLE_TIMBRES) begin : legacy
        assign bank_address=0;
        assign bank_operand=0;
        assign bank_gain=0;
        wavetable u_wavetable (.clk(clk), .addr(addr), .dout(wave));
    end else begin : timbres
        localparam integer STRIDE=SHARED_ARITHMETIC && BANK_LANES>2 ? BANK_LANES : 2;
        localparam integer SLOT=SHARED_ARITHMETIC ? BANK_LANE : 0;
        localparam integer FUNDAMENTAL_CLOCK=4+SLOT;
        localparam integer SECOND_CLOCK=4+STRIDE+SLOT;
        localparam integer THIRD_CLOCK=4+2*STRIDE+SLOT;
        localparam integer FIFTH_CLOCK=4+3*STRIDE+SLOT;
        localparam integer BRIGHT_CLOCK=SHARED_ARITHMETIC ?
            5+4*STRIDE+BANK_LANE : 12;
        localparam integer OUTPUT_CLOCK=BRIGHT_CLOCK+1;
        reg [6:0] local_cycle;
        wire [6:0] cycle=SHARED_ARITHMETIC ? bank_cycle : local_cycle;
        reg [31:0] snapshot;
        reg [31:0] harmonic_phase;
        wire signed [15:0] lookup_wave;
        reg signed [17:0] fundamental, second, third, fifth;
        reg signed [17:0] body, upper;
        reg [31:0] piano_phase2, piano_phase3, piano_phase5;
        reg phase_reset_frame;
        reg [31:0] phase_operand, integer_increment, stretch_increment;
        wire [31:0] phase_increment=integer_increment+stretch_increment;
        wire [31:0] updated_phase=phase_operand+phase_increment;
        reg [7:0] piano_gain1, piano_gain2, piano_gain3, piano_gain5;
        // A sine sample times any approved 8-bit gain fits signed 24 bits.
        reg signed [23:0] piano_h1, piano_h2, piano_h3, piano_h5;
        wire signed [28:0] piano_upper_sum =
            $signed({{5{piano_h2[23]}}, piano_h2}) +
            $signed({{5{piano_h3[23]}}, piano_h3}) +
            $signed({{5{piano_h5[23]}}, piano_h5});
        wire signed [28:0] piano_upper = piano_upper_sum >>> 8;
        reg signed [23:0] bright_product;
        wire signed [26:0] piano_bright = bright_product;
        wire signed [28:0] piano_result = (piano_h1 >>> 8) +
            piano_upper + (piano_bright >>> 8);
        // Instrument 2 is rendered by voice.u_bell, not the obsolete flute path.
        wire signed [17:0] result = instrument == 2 ? 18'sd0 :
            instrument == 0 ? piano_result :
                              body + (bright_product >>> 7);
        reg signed [17:0] multiply_wave;
        reg [7:0] multiply_gain;
        wire signed [26:0] multiply_product;
        reg signed [15:0] output_wave;
        assign bank_address=harmonic_phase[31:20];
        assign bank_operand=multiply_wave;
        assign bank_gain=multiply_gain;
        if(SHARED_ARITHMETIC) begin : external_arithmetic
            assign lookup_wave=bank_lookup_wave;
            assign multiply_product=bank_product;
        end else begin : internal_arithmetic
        assign multiply_product=multiply_wave*$signed({1'b0,multiply_gain});
        wavetable u_wavetable (
            .clk(clk), .addr(harmonic_phase[31:20]), .dout(lookup_wave)
        );
        end
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
            case (cycle)
                SECOND_CLOCK-1: harmonic_phase = instrument == 0 ?
                    piano_phase2 :
                    (snapshot << 1);
                THIRD_CLOCK-1: harmonic_phase = instrument == 0 ?
                    piano_phase3 :
                    (snapshot + (snapshot << 1));
                FIFTH_CLOCK-1: harmonic_phase = instrument == 0 ?
                    piano_phase5 :
                    (snapshot + (snapshot << 2));
                default: harmonic_phase = snapshot;
            endcase
            case(cycle)
                1: begin
                    phase_operand=piano_phase2;
                    integer_increment=fc << 1;
                    stretch_increment=fc >> 11;
                end
                2: begin
                    phase_operand=piano_phase3;
                    integer_increment=fc+(fc << 1);
                    stretch_increment=fc >> 9;
                end
                default: begin
                    phase_operand=piano_phase5;
                    integer_increment=fc+(fc << 2);
                    stretch_increment=fc >> 7;
                end
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
            case (cycle)
                FUNDAMENTAL_CLOCK+1: begin multiply_wave = fundamental; multiply_gain = piano_gain1; end
                SECOND_CLOCK+1: begin multiply_wave = second; multiply_gain = piano_gain2; end
                THIRD_CLOCK+1: begin multiply_wave = third; multiply_gain = piano_gain3; end
                FIFTH_CLOCK+1: begin multiply_wave = fifth; multiply_gain = piano_gain5; end
                default: begin
                    // The original upper-partial bound is within signed 16 bits.
                    multiply_wave = instrument == 0 ?
                        $signed(piano_upper[15:0]) : upper;
                    multiply_gain = brightness;
                end
            endcase
        end
        // Accumulate stretched frequencies; scaling an already wrapped phase
        // would introduce a discontinuity at every fundamental-period wrap.
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                piano_phase2 <= 0; piano_phase3 <= 0; piano_phase5 <= 0;
                phase_reset_frame<=0;
            end else if (phase_load) begin
                piano_phase2 <= 0; piano_phase3 <= 0; piano_phase5 <= 0;
                phase_reset_frame<=1;
            end else if (sample_tick) begin
                phase_reset_frame<=0;
            end else if(!phase_reset_frame) begin
                case(cycle)
                    1: piano_phase2<=updated_phase;
                    2: piano_phase3<=updated_phase;
                    3: piano_phase5<=updated_phase;
                    default: ;
                endcase
            end
        end
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                local_cycle <= 0;
                snapshot <= 0;
                fundamental <= 0;
                second <= 0;
                third <= 0;
                fifth <= 0;
                piano_h1 <= 0; piano_h2 <= 0; piano_h3 <= 0; piano_h5 <= 0;
                bright_product <= 0;
                output_wave <= 0;
            end else if (sample_tick) begin
                local_cycle <= 1;
            end else if (cycle != 0) begin
                local_cycle <= local_cycle == OUTPUT_CLOCK ? 0 : local_cycle + 1'b1;
                case (cycle)
                    // Phase reset from the allocator completes at clock 1.
                    2: begin
                        snapshot <= phase;
                    end
                    FUNDAMENTAL_CLOCK: fundamental <= lookup_wave;
                    FUNDAMENTAL_CLOCK+1: piano_h1 <= multiply_product;
                    SECOND_CLOCK: second <= fc < 32'h40000000 ? lookup_wave : 16'sd0;
                    SECOND_CLOCK+1: piano_h2 <= multiply_product;
                    THIRD_CLOCK: third <= fc < 32'h2aaaaaaa ? lookup_wave : 16'sd0;
                    THIRD_CLOCK+1: piano_h3 <= multiply_product;
                    FIFTH_CLOCK: fifth <= fc < 32'h19999999 ? lookup_wave : 16'sd0;
                    FIFTH_CLOCK+1: piano_h5 <= multiply_product;
                    BRIGHT_CLOCK: bright_product <= multiply_product;
                    OUTPUT_CLOCK: output_wave <= result > 32767 ? 16'sh7fff :
                                       result < -32768 ? 16'sh8000 : result[15:0];
                    default: ;
                endcase
            end
        end
        assign wave = output_wave;
    end endgenerate
endmodule

// Interleave four ROM reads and five products per lane; state remains per voice.
module oscillator_bank #(
    parameter integer LANES=8
) (
    input wire clk,rst_n,sample_tick,
    input wire [LANES*12-1:0] addresses,
    input wire [LANES*18-1:0] operands,
    input wire [LANES*8-1:0] gains,
    output reg [6:0] cycle,
    output wire signed [15:0] lookup_wave,
    output wire signed [26:0] product
);
    localparam integer LANE_BITS=LANES>1 ? $clog2(LANES) : 1;
    localparam integer STRIDE=LANES>2 ? LANES : 2;
    wire [LANE_BITS-1:0] read_lane=cycle>=3 && cycle<3+4*STRIDE ?
        (cycle-3)%STRIDE : 0;
    wire [LANE_BITS-1:0] multiply_lane=cycle>=5 && cycle<5+5*STRIDE ?
        (cycle-5)%STRIDE : 0;
    wire signed [17:0] operand=operands[multiply_lane*18+:18];
    wire [7:0] gain=gains[multiply_lane*8+:8];
    assign product=operand*$signed({1'b0,gain});
    wavetable shared_table(
        .clk(clk),.addr(addresses[read_lane*12+:12]),.dout(lookup_wave));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) cycle<=0;
        else if(sample_tick) cycle<=1;
        else if(cycle!=0) cycle<=cycle==5+5*STRIDE ? 0 : cycle+1'b1;
    end
endmodule

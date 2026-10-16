// A1/A2 sine path and A3 additive synthesis share the original phase/ROM.
`include "event_defs.vh"
module oscillator #(
    parameter integer ENABLE_TIMBRES = 0,
    parameter integer SHARED_ARITHMETIC = 0,
    parameter integer BANK_LANES = 8,
    parameter integer BANK_LANE = 0,
    parameter integer SHARED_STRETCH = 0,
    parameter integer SHARED_COEFFICIENTS = 0,
    parameter integer SHARED_PHASE_ADD = 0,
    parameter integer SHARED_UPPER_ADD = 0
) (
    input wire clk, rst_n, sample_tick, phase_load,
    input wire [31:0] fc,
    input wire [1:0] instrument,
    input wire [7:0] brightness,
    input wire [6:0] bank_cycle,
    input wire signed [15:0] bank_lookup_wave,
    input wire signed [26:0] bank_product,
    input wire [31:0] bank_phase_increment,
    input wire [31:0] bank_updated_phase,
    output wire [31:0] bank_phase_operand,
    input wire signed [25:0] bank_updated_upper,
    output wire signed [25:0] bank_upper_operand,
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
        assign bank_phase_operand=0;
        assign bank_upper_operand=0;
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
        localparam integer PHASE2_CLOCK=SHARED_STRETCH ? 1+SLOT : 1;
        localparam integer PHASE3_CLOCK=SHARED_STRETCH ? 1+STRIDE+SLOT : 2;
        localparam integer PHASE5_CLOCK=SHARED_STRETCH ? 1+2*STRIDE+SLOT : 3;
        reg [6:0] local_cycle;
        wire [6:0] cycle=SHARED_ARITHMETIC ? bank_cycle : local_cycle;
        reg [31:0] snapshot;
        reg [31:0] harmonic_phase;
        wire [31:0] harmonic_shift = cycle == FIFTH_CLOCK-1 ?
            (snapshot << 2) : (snapshot << 1);
        wire [31:0] harmonic_sum = snapshot + harmonic_shift;
        wire signed [15:0] lookup_wave;
        reg signed [17:0] fundamental, second, third, fifth;
        reg signed [17:0] body, upper;
        reg [31:0] piano_phase2, piano_phase3, piano_phase5;
        reg phase_reset_frame;
        wire [31:0] phase_operand=cycle==PHASE2_CLOCK ? piano_phase2 :
            cycle==PHASE3_CLOCK ? piano_phase3 : piano_phase5;
        wire [31:0] phase_increment;
        if(SHARED_STRETCH) begin : shared_stretch
            assign phase_increment=bank_phase_increment;
        end else begin : private_stretch
        reg [13:0] stretch_coefficient;
        // floor(fc * (n*2048 + k) / 2048) exactly equals
        // n*fc + floor(fc*k/2048), including the original modulo-32 wrap.
        wire [39:0] stretched_high=fc[31:6]*stretch_coefficient;
        reg [19:0] stretched_low;
        always @* begin
            case(cycle)
                1: stretched_low=({14'd0,fc[5:0]} << 12)+fc[5:0];
                2: stretched_low=({14'd0,fc[5:0]} << 12)+
                    ({14'd0,fc[5:0]} << 11)+({14'd0,fc[5:0]} << 2);
                default: stretched_low=({14'd0,fc[5:0]} << 13)+
                    ({14'd0,fc[5:0]} << 11)+({14'd0,fc[5:0]} << 4);
            endcase
        end
        wire [19:0] fractional_sum={stretched_high[4:0],6'b0}+stretched_low;
        assign phase_increment=stretched_high[36:5]+fractional_sum[19:11];
        always @* begin
            case(cycle)
                1: stretch_coefficient=14'd4097;
                2: stretch_coefficient=14'd6148;
                default: stretch_coefficient=14'd10256;
            endcase
        end
        end
        assign bank_phase_operand=phase_operand;
        wire [31:0] updated_phase=SHARED_PHASE_ADD ? bank_updated_phase :
            phase_operand+phase_increment;
        reg [7:0] piano_gain1, piano_gain2, piano_gain3, piano_gain5;
        // A sine sample times any approved 8-bit gain fits signed 24 bits.
        reg signed [23:0] piano_h1;
        // Products arrive in harmonic order. Accumulate before BRIGHT_CLOCK
        // rather than storing three products and adding them in parallel.
        reg signed [25:0] piano_upper_sum;
        assign bank_upper_operand=piano_upper_sum;
        wire signed [25:0] upper_product=
            $signed({{2{multiply_product[23]}},multiply_product[23:0]});
        wire signed [25:0] updated_upper=SHARED_UPPER_ADD ?
            bank_updated_upper : piano_upper_sum+upper_product;
        wire signed [25:0] piano_upper_shifted = piano_upper_sum >>> 8;
        wire signed [17:0] piano_upper = piano_upper_shifted[17:0];
        reg signed [23:0] bright_product;
        wire signed [23:0] piano_bright = bright_product;
        // The original result is truncated to 18 bits before saturation.
        wire signed [23:0] piano_h1_shifted = piano_h1 >>> 8;
        wire signed [17:0] result_base = instrument == 0 ?
            piano_h1_shifted[17:0] : body;
        wire signed [17:0] result_upper = instrument == 0 ?
            (piano_upper >>> 1) : 18'sd0;
        wire signed [23:0] piano_bright_shifted = piano_bright >>> 7;
        wire signed [29:0] summed_result_math =
            {{6{result_base[17]}},result_base} +
            {{6{result_upper[17]}},result_upper} +
            {{6{piano_bright_shifted[23]}},piano_bright_shifted};
        wire signed [23:0] summed_result_wide = summed_result_math[23:0];
        wire signed [17:0] summed_result = summed_result_wide[17:0];
        // Instrument 2 is rendered by voice.u_bell, not the obsolete flute path.
        wire signed [17:0] result = instrument == 2 ? 18'sd0 :
            summed_result;
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
            if (SHARED_COEFFICIENTS) begin
                piano_gain1 = 0; piano_gain2 = 0;
                piano_gain3 = 0; piano_gain5 = 0;
            end else if (fc < 32'd12418159) begin
                piano_gain1 = 96; piano_gain2 = 64;
                piano_gain3 = 32; piano_gain5 = 16;
            end else if (fc < 32'd24836318) begin
                piano_gain1 = 128; piano_gain2 = 64;
                piano_gain3 = 24; piano_gain5 = 8;
            end else if (fc < 32'd49672636) begin
                piano_gain1 = 168; piano_gain2 = 40;
                piano_gain3 = 12; piano_gain5 = 3;
            end else begin
                piano_gain1 = 192; piano_gain2 = 28;
                piano_gain3 = 6; piano_gain5 = 1;
            end
            case (cycle)
                SECOND_CLOCK-1: harmonic_phase = instrument == 0 ?
                    piano_phase2 :
                    (snapshot << 1);
                THIRD_CLOCK-1: harmonic_phase = instrument == 0 ?
                    piano_phase3 :
                    harmonic_sum;
                FIFTH_CLOCK-1: harmonic_phase = instrument == 0 ?
                    piano_phase5 :
                    harmonic_sum;
                default: harmonic_phase = snapshot;
            endcase
            body = instrument == 2 ? 18'sd0 :
                (fundamental >>> 1) +
                (instrument == 3 ? (second >>> 3) :
                 instrument == 0 ? (fundamental >>> 3) : 18'sd0);
            upper = instrument == 2 ? 18'sd0 :
                (instrument == 0 ? (second >>> 1) : (second >>> 3)) +
                (third >>> 2) + (fifth >>> 3);
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
                    PHASE2_CLOCK: piano_phase2<=updated_phase;
                    PHASE3_CLOCK: piano_phase3<=updated_phase;
                    PHASE5_CLOCK: piano_phase5<=updated_phase;
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
                piano_h1 <= 0; piano_upper_sum <= 0;
                bright_product <= 0;
                output_wave <= 0;
            end else if (sample_tick) begin
                local_cycle <= 1;
            end else if (cycle != 0) begin
                local_cycle <= local_cycle == OUTPUT_CLOCK ? 4'd0 :
                    local_cycle + 4'd1;
                case (cycle)
                    // Phase reset from the allocator completes at clock 1.
                    2: begin
                        snapshot <= phase;
                    end
                    FUNDAMENTAL_CLOCK: fundamental <= lookup_wave;
                    FUNDAMENTAL_CLOCK+1: piano_h1 <= multiply_product[23:0];
                    SECOND_CLOCK: second <= fc < 32'h40000000 ? lookup_wave : 16'sd0;
                    SECOND_CLOCK+1: piano_upper_sum <= upper_product;
                    THIRD_CLOCK: third <= fc < 32'h2aaaaaaa ? lookup_wave : 16'sd0;
                    THIRD_CLOCK+1: piano_upper_sum <= updated_upper;
                    FIFTH_CLOCK: fifth <= fc < 32'h19999999 ? lookup_wave : 16'sd0;
                    FIFTH_CLOCK+1: piano_upper_sum <= updated_upper;
                    BRIGHT_CLOCK: bright_product <= multiply_product[23:0];
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
    parameter integer LANES=8,
    parameter integer SHARED_STRETCH=0,
    parameter integer SHARED_COEFFICIENTS=0,
    parameter integer SHARED_PHASE_ADD=0,
    parameter integer SHARED_UPPER_ADD=0
) (
    input wire clk,rst_n,sample_tick,
    input wire [LANES*12-1:0] addresses,
    input wire [LANES*18-1:0] operands,
    input wire [LANES*8-1:0] gains,
    input wire [LANES*32-1:0] fcs,
    input wire [LANES*32-1:0] phase_operands,
    input wire [LANES*26-1:0] upper_operands,
    output reg [6:0] cycle,
    output wire signed [15:0] lookup_wave,
    output wire signed [26:0] product,
    output wire [31:0] phase_increment,
    output wire [31:0] updated_phase,
    output wire signed [25:0] updated_upper
);
    localparam integer LANE_BITS=LANES>1 ? $clog2(LANES) : 1;
    localparam integer STRIDE=LANES>2 ? LANES : 2;
    wire [LANE_BITS-1:0] phase_lane=cycle>=1 && cycle<1+3*STRIDE ?
        (cycle-1)%STRIDE : 0;
    assign updated_phase=SHARED_PHASE_ADD ?
        phase_operands[phase_lane*32+:32]+phase_increment : 32'd0;
    wire [LANE_BITS-1:0] read_lane=cycle>=3 && cycle<3+4*STRIDE ?
        (cycle-3)%STRIDE : 0;
    wire [LANE_BITS-1:0] multiply_lane=cycle>=5 && cycle<5+5*STRIDE ?
        (cycle-5)%STRIDE : 0;
    wire signed [17:0] operand=operands[multiply_lane*18+:18];
    assign updated_upper=SHARED_UPPER_ADD ?
        $signed(upper_operands[multiply_lane*26+:26])+
        $signed({{2{product[23]}},product[23:0]}) : 26'sd0;
    wire [7:0] gain;
    generate if(SHARED_COEFFICIENTS) begin : coefficients
        wire [31:0] fc=fcs[multiply_lane*32+:32];
        reg [7:0] g1,g2,g3,g5;
        reg [7:0] selected_gain;
        always @* begin
            if(fc<32'd12418159) begin
                g1=96;g2=64;g3=32;g5=16;
            end else if(fc<32'd24836318) begin
                g1=128;g2=64;g3=24;g5=8;
            end else if(fc<32'd49672636) begin
                g1=168;g2=40;g3=12;g5=3;
            end else begin
                g1=192;g2=28;g3=6;g5=1;
            end
            if(cycle>=5 && cycle<5+STRIDE) selected_gain=g1;
            else if(cycle>=5+STRIDE && cycle<5+2*STRIDE) selected_gain=g2;
            else if(cycle>=5+2*STRIDE && cycle<5+3*STRIDE) selected_gain=g3;
            else if(cycle>=5+3*STRIDE && cycle<5+4*STRIDE) selected_gain=g5;
            else selected_gain=gains[multiply_lane*8+:8];
        end
        assign gain=selected_gain;
    end else begin : private_coefficients
        assign gain=gains[multiply_lane*8+:8];
    end endgenerate
    assign product=operand*$signed({1'b0,gain});
    generate if(SHARED_STRETCH) begin : stretch
        wire [LANE_BITS-1:0] lane=cycle>=1 && cycle<1+3*STRIDE ?
            (cycle-1)%STRIDE : 0;
        wire [31:0] fc=fcs[lane*32+:32];
        reg [13:0] coefficient;
        reg [19:0] low_product;
        always @* begin
            if(cycle<1+STRIDE) begin
                coefficient=4097;
                low_product=({14'd0,fc[5:0]} << 12)+fc[5:0];
            end else if(cycle<1+2*STRIDE) begin
                coefficient=6148;
                low_product=({14'd0,fc[5:0]} << 12)+
                    ({14'd0,fc[5:0]} << 11)+({14'd0,fc[5:0]} << 2);
            end else begin
                coefficient=10256;
                low_product=({14'd0,fc[5:0]} << 13)+
                    ({14'd0,fc[5:0]} << 11)+({14'd0,fc[5:0]} << 4);
            end
        end
        wire [39:0] high_product=fc[31:6]*coefficient;
        wire [19:0] low_sum={high_product[4:0],6'b0}+low_product;
        assign phase_increment=high_product[36:5]+low_sum[19:11];
    end else begin : no_stretch
        assign phase_increment=0;
    end endgenerate
    wavetable shared_table(
        .clk(clk),.addr(addresses[read_lane*12+:12]),.dout(lookup_wave));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) cycle<=0;
        else if(sample_tick) cycle<=1;
        else if(cycle!=0) cycle<=cycle==5+5*STRIDE ? 7'd0 : cycle+7'd1;
    end
endmodule

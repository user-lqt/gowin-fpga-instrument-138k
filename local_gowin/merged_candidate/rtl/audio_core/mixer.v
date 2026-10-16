module mixer #(
    parameter integer VOICES = 4
) (
    input  wire [VOICES*24-1:0] voice_samples,
    input  wire [15:0]        volume,
    output wire signed [23:0] audio,
    output wire               overload_flag
);
    reg signed [31:0] sum;
    integer i;

    always @(*) begin
        sum = 32'sd0;
        for (i = 0; i < VOICES; i = i + 1)
            sum = sum + $signed({{8{voice_samples[i*24+23]}},
                                 voice_samples[i*24 +: 24]});
    end

    wire signed [48:0] scaled =
        (sum * $signed({1'b0, volume})) >>> 16;

    assign overload_flag = (scaled > 45'sd8388607) ||
                           (scaled < -45'sd8388608);
    assign audio = scaled > 45'sd8388607 ? 24'sh7fffff :
                   scaled < -45'sd8388608 ? 24'sh800000 : scaled[23:0];
endmodule

module voice_gain_bank #(
    parameter integer LANES=4,
    parameter integer VELOCITY_START=14
) (
    input wire clk,rst_n,sample_tick,
    input wire [LANES*27-1:0] operands_a,
    input wire [LANES*18-1:0] operands_b,
    output wire [LANES*4-1:0] steps,
    output wire signed [44:0] product
);
    localparam integer INDEX_BITS=LANES>1 ? $clog2(LANES) : 1;
    reg [7:0] cycle;
    reg [INDEX_BITS-1:0] lane;
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
    wire signed [26:0] a=operands_a[lane*27+:27];
    wire signed [17:0] b=operands_b[lane*18+:18];
    assign product=a*b;
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
module mixer_serial #(
    parameter integer VOICES = 32
) (
    input wire clk, rst_n, start,
    input wire [VOICES*24-1:0] voice_samples,
    input wire [15:0] volume,
    output reg signed [23:0] audio,
    output reg overload_flag
);
    reg [1:0] state;
    localparam integer INDEX_BITS=VOICES>1 ? $clog2(VOICES) : 1;
    reg [INDEX_BITS-1:0] index;
    localparam integer SUM_BITS = 24 + $clog2(VOICES);
    localparam integer PRODUCT_BITS = SUM_BITS + 17;
    // Preserve full-scale sums for both 32- and 64-voice configurations.
    reg signed [SUM_BITS-1:0] sum;
    reg signed [PRODUCT_BITS-1:0] product;
    wire signed [PRODUCT_BITS-1:0] scaled = product >>> 16;
    reg signed [23:0] current_sample;
    integer slot;
    // Select fixed words with one shared decoder, not a variable bit offset.
    always @* begin
        current_sample=0;
        for(slot=0;slot<VOICES;slot=slot+1)
            current_sample=current_sample |
                (voice_samples[slot*24+:24] & {24{index==slot}});
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= 0;
            index <= 0;
            sum <= 0;
            product <= 0;
            audio <= 0;
            overload_flag <= 0;
        end else if (start) begin
            state <= 1;
            index <= 0;
            sum <= 0;
        end else case (state)
            1: begin
                sum <= sum + current_sample;
                if (index == VOICES-1) state <= 2;
                else index <= index + 1'b1;
            end
            2: begin
                product <= sum * $signed({1'b0, volume});
                state <= 3;
            end
            3: begin
                audio <= scaled > 46'sd8388607 ? 24'sh7fffff :
                         scaled < -46'sd8388608 ? 24'sh800000 : scaled[23:0];
                overload_flag <= scaled > 46'sd8388607 ||
                                 scaled < -46'sd8388608;
                state <= 0;
            end
            default: ;
        endcase
    end
endmodule

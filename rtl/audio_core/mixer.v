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
    reg [$clog2(VOICES):0] index;
    reg signed [31:0] sum;
    reg signed [48:0] product;
    wire signed [48:0] scaled = product >>> 16;
    wire signed [23:0] current_sample = voice_samples[index*24 +: 24];
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
                audio <= scaled > 8388607 ? 24'sh7fffff :
                         scaled < -8388608 ? 24'sh800000 : scaled[23:0];
                overload_flag <= scaled > 8388607 || scaled < -8388608;
                state <= 0;
            end
            default: ;
        endcase
    end
endmodule

// MCP3008 single-ended SPI master.
// SPI mode 0: SCLK idles low, DOUT is sampled on rising edges.
// One transaction sends start, single-ended, D2..D0, then receives
// the null bit and ten data bits.  The channel is latched at start.
module mcp3008_spi #(
    parameter integer CLK_DIV = 12
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [2:0] channel,
    input  wire       miso,
    output reg        sclk,
    output reg        mosi,
    output reg        cs_n,
    output reg        busy,
    output reg        done,
    output reg [9:0]  data
);
    reg [15:0] div_count;
    reg [4:0]  rise_count;
    reg [4:0]  command;
    reg [9:0]  shift_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_count <= 16'd0;
            rise_count <= 5'd0;
            command <= 5'd0;
            shift_data <= 10'd0;
            sclk <= 1'b0;
            mosi <= 1'b0;
            cs_n <= 1'b1;
            busy <= 1'b0;
            done <= 1'b0;
            data <= 10'd0;
        end else begin
            done <= 1'b0;

            if (!busy) begin
                sclk <= 1'b0;
                cs_n <= 1'b1;
                mosi <= 1'b0;
                div_count <= 16'd0;
                if (start) begin
                    // 1=start, 1=single-ended, then D2..D0.
                    command <= {2'b11, channel};
                    shift_data <= 10'd0;
                    rise_count <= 5'd0;
                    cs_n <= 1'b0;
                    mosi <= 1'b1;
                    busy <= 1'b1;
                end
            end else if (div_count == CLK_DIV - 1) begin
                div_count <= 16'd0;
                if (!sclk) begin
                    // Mode 0 samples the converter output at this edge.
                    sclk <= 1'b1;
                    if ((rise_count >= 5'd6) && (rise_count <= 5'd15))
                        shift_data <= {shift_data[8:0], miso};
                end else begin
                    sclk <= 1'b0;
                    if (rise_count == 5'd15) begin
                        // The last bit was captured on the preceding rising edge.
                        data <= shift_data;
                        cs_n <= 1'b1;
                        mosi <= 1'b0;
                        busy <= 1'b0;
                        done <= 1'b1;
                    end else begin
                        rise_count <= rise_count + 1'b1;
                        // Set DIN before the next rising edge.
                        if (rise_count < 5'd4)
                            mosi <= command[4 - (rise_count + 1'b1)];
                        else
                            mosi <= 1'b0;
                    end
                end
            end else begin
                div_count <= div_count + 1'b1;
            end
        end
    end
endmodule

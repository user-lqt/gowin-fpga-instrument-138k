`timescale 1ns/1ps
// Round-robin sampler for CH0=FSR, CH1=VRx and CH2=VRy.
module mcp3008_sampler #(
    parameter integer CLK_DIV=12,
    parameter integer CHANNEL_COUNT=3,
    parameter integer SAMPLE_DIV=0 // Start interval; 4096 gives 1 kS/s/channel.
) (
    input wire clk,rst_n,
    input wire adc_miso,
    output wire adc_cs_n,adc_sclk,adc_mosi,
    output wire busy,
    output reg sample_valid,
    output reg sample_error,
    output reg [2:0] sample_channel,
    output reg [9:0] ch0_data,ch1_data,ch2_data
);
    reg start;
    reg [2:0] channel;
    reg [31:0] wait_cycles;
    wire done, conversion_valid;
    wire [9:0] adc_data;
    mcp3008_spi #(.CLK_DIV(CLK_DIV)) spi(
        .clk(clk),.rst_n(rst_n),.start(start),.channel(channel),.adc_miso(adc_miso),
        .adc_cs_n(adc_cs_n),.adc_sclk(adc_sclk),.adc_mosi(adc_mosi),.busy(busy),
        .done(done),.adc_data(adc_data),.conversion_valid(conversion_valid)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin start<=0;channel<=0;sample_valid<=0;sample_error<=0;sample_channel<=0;wait_cycles<=0;
            ch0_data<=0;ch1_data<=0;ch2_data<=0;
        end else begin
            start<=0;sample_valid<=0;sample_error<=0;
            if(wait_cycles!=0) wait_cycles<=wait_cycles-1'b1;
            if(!busy && !done && !start && wait_cycles==0) begin
                start<=1;
                wait_cycles<=SAMPLE_DIV>0 ? SAMPLE_DIV-1 : 0;
            end
            if(done) begin
                sample_valid<=conversion_valid;
                sample_error<=!conversion_valid;
                sample_channel<=channel;
                case(channel)
                    0:ch0_data<=conversion_valid ? adc_data : 10'd0;
                    1:ch1_data<=conversion_valid ? adc_data : 10'd0;
                    2:ch2_data<=conversion_valid ? adc_data : 10'd0;
                    default:;
                endcase
                channel <= channel==CHANNEL_COUNT-1 ? 3'd0 : channel+3'd1;
            end
        end
    end
endmodule

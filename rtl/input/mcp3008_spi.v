`timescale 1ns/1ps
// MCP3008 single-ended SPI mode 0 master.
// Five command clocks, one acquisition clock, one null clock, then B9..B0.
// sclk is derived from clk and idles low; MOSI changes on falling edges and
// DOUT is sampled on rising edges.
module mcp3008_spi #(
    parameter integer CLK_DIV = 12
) (
    input wire clk, rst_n,
    input wire start,
    input wire [2:0] channel,
    input wire adc_miso,
    output reg adc_cs_n, adc_sclk, adc_mosi,
    output reg busy, done,
    output reg [9:0] adc_data,
    output reg conversion_valid
);
    function integer count_width;
        input integer n;
        integer v;
        begin
            v=n-1; count_width=0;
            while(v>0) begin count_width=count_width+1;v=v>>1;end
            if(count_width<1) count_width=1;
        end
    endfunction
    localparam integer DIV_W=count_width(CLK_DIV);
    localparam [DIV_W-1:0] DIV_LAST=CLK_DIV-1;
    reg [DIV_W-1:0] div_count;
    reg [4:0] rising_index;
    reg [4:0] command;
    reg [9:0] sample_shift;
    reg finish_pending, null_valid;
    wire spi_tick = div_count==DIV_LAST;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            adc_cs_n<=1;adc_sclk<=0;adc_mosi<=0;busy<=0;done<=0;
            adc_data<=0;div_count<=0;rising_index<=0;command<=0;
            sample_shift<=0;finish_pending<=0;null_valid<=0;conversion_valid<=0;
        end else begin
            done<=0;
            if(!busy) begin
                adc_cs_n<=1;adc_sclk<=0;adc_mosi<=0;div_count<=0;
                if(start) begin
                    busy<=1;adc_cs_n<=0;
                    command<={2'b11,channel};
                    adc_mosi<=1;
                    rising_index<=0;sample_shift<=0;finish_pending<=0;
                    null_valid<=0;conversion_valid<=0;
                end
            end else if(spi_tick) begin
                div_count<=0;
                if(!adc_sclk) begin
                    // Rising edge: consume the command/null/data bit.
                    adc_sclk<=1;
                    // D0 is latched on clock 5, null appears after falling
                    // clock 6, and B9 appears after falling clock 7 (DS21295D).
                    if(rising_index==6) null_valid<=!adc_miso;
                    if(rising_index>=7 && rising_index<=16)
                        sample_shift <= {sample_shift[8:0],adc_miso};
                    if(rising_index==16) finish_pending<=1;
                    rising_index<=rising_index+1'b1;
                end else begin
                    // Falling edge: prepare the next command bit.
                    adc_sclk<=0;
                    if(finish_pending) begin
                        adc_cs_n<=1;busy<=0;done<=1;
                        adc_data<=sample_shift;
                        conversion_valid<=null_valid;
                        finish_pending<=0;adc_mosi<=0;
                    end else if(rising_index<5)
                        adc_mosi<=command[4-rising_index];
                    else adc_mosi<=0;
                end
            end else div_count<=div_count+1'b1;
        end
    end
endmodule

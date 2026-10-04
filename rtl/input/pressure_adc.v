// FSR pressure path through MCP3008 CH0.
// The module deliberately stops at a reusable expression output.  The audio
// core can consume modulation_value through PARAM_MODULATION later, while a
// standalone ADC top can expose raw_value for hardware calibration.
module pressure_adc #(
    parameter integer SPI_CLK_DIV = 12,
    parameter integer SAMPLE_DIV = 12288, // 1 kS/s at 12.288 MHz
    parameter integer FILTER_SHIFT = 3,   // EMA alpha = 1 / 2^FILTER_SHIFT
    parameter integer ZERO_LEVEL = 0,
    parameter integer FULL_SCALE = 1023,
    parameter integer DEADBAND = 0,
    parameter integer ENABLE_FAULT_CHECK = 0,
    parameter integer FAULT_LOW_LEVEL = 0,
    parameter integer FAULT_HIGH_LEVEL = 1023
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       adc_miso,
    output wire       adc_sclk,
    output wire       adc_mosi,
    output wire       adc_cs_n,
    output wire       adc_busy,
    output wire       sensor_valid,
    output wire       sensor_fault,
    output reg        sample_valid,
    output reg [9:0]  raw_value,
    output reg [9:0]  filtered_value,
    output wire [15:0] modulation_value
);
    reg [31:0] sample_count;
    reg        have_sample;
    wire       sample_start;
    wire       spi_done;
    wire [9:0] spi_data;
    wire [2:0] channel = 3'd0;
    reg [9:0] filter_step;
    wire mapper_valid;

    assign sample_start = !adc_busy && (sample_count == SAMPLE_DIV - 1);

    mcp3008_spi #(.CLK_DIV(SPI_CLK_DIV)) u_mcp3008_spi (
        .clk(clk), .rst_n(rst_n), .start(sample_start), .channel(channel),
        .miso(adc_miso), .sclk(adc_sclk), .mosi(adc_mosi), .cs_n(adc_cs_n),
        .busy(adc_busy), .done(spi_done), .data(spi_data)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count <= 32'd0;
            have_sample <= 1'b0;
            sample_valid <= 1'b0;
            raw_value <= 10'd0;
            filtered_value <= 10'd0;
        end else begin
            sample_valid <= spi_done;
            if (sample_start)
                sample_count <= 32'd0;
            else if (sample_count < SAMPLE_DIV - 1)
                sample_count <= sample_count + 1'b1;

            if (spi_done) begin
                raw_value <= spi_data;
                // Round the EMA step away from zero so small changes converge.
                if (!have_sample) begin
                    filtered_value <= spi_data;
                    have_sample <= 1'b1;
                end else if (spi_data >= filtered_value) begin
                    filter_step = ((spi_data - filtered_value) >> FILTER_SHIFT);
                    if ((filter_step == 0) && (spi_data != filtered_value))
                        filter_step = 1;
                    filtered_value <= filtered_value + filter_step;
                end else begin
                    filter_step = ((filtered_value - spi_data) >> FILTER_SHIFT);
                    if (filter_step == 0)
                        filter_step = 1;
                    filtered_value <= filtered_value - filter_step;
                end
            end
        end
    end

    expression_mapper #(
        .ZERO_LEVEL(ZERO_LEVEL), .FULL_SCALE(FULL_SCALE),
        .DEADBAND(DEADBAND), .ENABLE_FAULT_CHECK(ENABLE_FAULT_CHECK),
        .FAULT_LOW_LEVEL(FAULT_LOW_LEVEL), .FAULT_HIGH_LEVEL(FAULT_HIGH_LEVEL)
    ) u_expression_mapper (
        .adc_value(filtered_value), .modulation_value(modulation_value),
        .sensor_valid(mapper_valid), .sensor_fault(sensor_fault)
    );

    assign sensor_valid = have_sample && mapper_valid;
endmodule

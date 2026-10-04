`timescale 1ns/1ps

module tb_pressure_adc;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg miso = 1'b0;
    wire sclk, mosi, cs_n, busy, sensor_valid, sensor_fault;
    wire sample_valid;
    wire [9:0] raw_value, filtered_value;
    wire [15:0] modulation_value;
    reg [9:0] adc_value = 10'd700;
    integer edge_count;
    integer mosi_count;
    integer sample_count;

    always #5 clk = ~clk;

    pressure_adc #(
        .SPI_CLK_DIV(2), .SAMPLE_DIV(500), .FILTER_SHIFT(2),
        .ZERO_LEVEL(100), .FULL_SCALE(900)
    ) dut (
        .clk(clk), .rst_n(rst_n), .adc_miso(miso),
        .adc_sclk(sclk), .adc_mosi(mosi), .adc_cs_n(cs_n), .adc_busy(busy),
        .sensor_valid(sensor_valid), .sensor_fault(sensor_fault),
        .sample_valid(sample_valid), .raw_value(raw_value),
        .filtered_value(filtered_value), .modulation_value(modulation_value)
    );

    // MCP3008 mode-0 response model.  After the command and null bit, B9..B0
    // are made valid before the following rising edge.
    always @(negedge sclk or posedge cs_n) begin
        if (cs_n) begin
            edge_count <= 0;
            mosi_count <= 0;
            miso <= 1'b0;
        end else begin
            if ((edge_count >= 5) && (edge_count <= 14))
                miso <= adc_value[14 - edge_count];
            else
                miso <= 1'b0;
            edge_count <= edge_count + 1;
        end
    end

    // Verify the command seen by the ADC: start, single-ended, CH0.
    always @(posedge sclk) begin
        if (!cs_n) begin
            if ((mosi_count == 0 || mosi_count == 1) && (mosi !== 1'b1)) begin
                $display("FAIL command bit %0d=%b", mosi_count, mosi);
                $finish;
            end
            if ((mosi_count >= 2) && (mosi_count <= 4) && (mosi !== 1'b0)) begin
                $display("FAIL channel bit %0d=%b", mosi_count, mosi);
                $finish;
            end
            mosi_count = mosi_count + 1;
        end
    end

    always @(posedge clk) begin
        if (sample_valid) begin
            sample_count = sample_count + 1;
            if (raw_value !== adc_value) begin
                $display("FAIL raw=%0d expected=%0d", raw_value, adc_value);
                $finish;
            end
            if (modulation_value !== 16'd49151) begin
                $display("FAIL modulation=%0d", modulation_value);
                $finish;
            end
            if (sensor_fault || !sensor_valid) begin
                $display("FAIL unexpected sensor fault");
                $finish;
            end
            if (sample_count == 2) begin
                $display("PASS pressure ADC raw=%0d filtered=%0d modulation=%0d",
                    raw_value, filtered_value, modulation_value);
                $finish;
            end
        end
    end

    initial begin
        edge_count = 0;
        mosi_count = 0;
        sample_count = 0;
        #40 rst_n = 1'b1;
        #30000;
        $display("FAIL timeout");
        $finish;
    end
endmodule

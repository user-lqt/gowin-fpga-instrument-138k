`include "event_defs.vh"
// Consume CH0 from the shared ADC; this module never drives the SPI bus.
// Q8 EMA preserves sub-count filter state. Publish after the mapper settles.
module fsr_expression_control #(
    parameter integer ZERO_LEVEL = 1,
    parameter integer FULL_SCALE = 899,
    parameter integer DEADBAND = 8,
    parameter integer FILTER_SHIFT = 3
) (
    input wire clk, rst_n,
    input wire sample_valid,
    input wire sample_error,
    input wire [2:0] sample_channel,
    input wire [9:0] ch0_data,
    output reg param_valid,
    output wire [3:0] param_id,
    output reg [15:0] param_value,
    output wire [9:0] filtered_value,
    output wire [15:0] modulation_value,
    output reg sensor_ready
);
    reg [17:0] filter_acc;
    reg publish_pending, sent;
    reg [15:0] last_sent;
    wire accept = sample_valid && sample_channel == 3'd0;
    wire signed [18:0] filter_error =
        $signed({1'b0, ch0_data, 8'd0}) - $signed({1'b0, filter_acc});
    wire signed [18:0] next_acc =
        $signed({1'b0, filter_acc}) + (filter_error >>> FILTER_SHIFT);
    wire [17:0] rounded_acc = filter_acc + 18'd128;
    assign filtered_value = rounded_acc[17:8];
    assign param_id = `PARAM_MODULATION;

    expression_mapper #(
        .ZERO_LEVEL(ZERO_LEVEL), .FULL_SCALE(FULL_SCALE), .DEADBAND(DEADBAND)
    ) u_mapper (
        .adc_value(filtered_value), .modulation_value(modulation_value),
        .sensor_valid(), .sensor_fault()
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            filter_acc <= 0;
            sensor_ready <= 0;
            publish_pending <= 0;
            sent <= 0;
            last_sent <= 0;
            param_valid <= 0;
            param_value <= 0;
        end else begin
            param_valid <= 0;
            publish_pending <= accept;
            if (sample_error && sample_channel == 3'd0) begin
                filter_acc <= 0;
                sensor_ready <= 0;
                publish_pending <= 0;
                // A pulled-high DOUT is a failed transaction, not full pressure.
                if (!sent || last_sent != 0) begin
                    param_valid <= 1;
                    param_value <= 0;
                    last_sent <= 0;
                    sent <= 1;
                end
            end else begin
                if (accept) begin
                    filter_acc <= sensor_ready ? next_acc[17:0] : {ch0_data, 8'd0};
                    sensor_ready <= 1;
                end
                if (publish_pending && (!sent || modulation_value != last_sent)) begin
                    param_valid <= 1;
                    param_value <= modulation_value;
                    last_sent <= modulation_value;
                    sent <= 1;
                end
            end
        end
    end
endmodule

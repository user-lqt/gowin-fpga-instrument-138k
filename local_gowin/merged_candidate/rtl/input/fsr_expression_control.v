`include "event_defs.vh"
// Consume CH0 from the shared ADC; this module never drives the SPI bus.
// The first 16 successful samples establish the unloaded sensor baseline.
// Q8 EMA preserves sub-count filter state. Publish after calibration settles.
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
    reg [13:0] baseline_sum;
    reg [4:0] baseline_count;
    reg [9:0] baseline;
    reg calibration_done;
    reg publish_pending, sent;
    reg [15:0] last_sent;
    wire accept = sample_valid && sample_channel == 3'd0;
    wire signed [18:0] filter_error =
        $signed({1'b0, ch0_data, 8'd0}) - $signed({1'b0, filter_acc});
    wire signed [18:0] next_acc =
        $signed({1'b0, filter_acc}) + (filter_error >>> FILTER_SHIFT);
    wire [17:0] rounded_acc = filter_acc + 18'd128;
    assign filtered_value = rounded_acc[17:8];
    wire [14:0] baseline_total =
        {1'b0,baseline_sum} + {5'd0,ch0_data} + 15'd8;
    wire [10:0] release_threshold = baseline + DEADBAND;
    wire [10:0] calibrated_value_wide = filtered_value <= release_threshold ?
        ZERO_LEVEL : filtered_value;
    wire [9:0] calibrated_value = calibrated_value_wide > 11'd1023 ?
        10'd1023 : calibrated_value_wide[9:0];
    assign param_id = `PARAM_MODULATION;

    expression_mapper #(
        .ZERO_LEVEL(ZERO_LEVEL), .FULL_SCALE(FULL_SCALE), .DEADBAND(DEADBAND)
    ) u_mapper (
        .adc_value(calibrated_value), .modulation_value(modulation_value),
        .sensor_valid(), .sensor_fault()
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            filter_acc <= 0;
            baseline_sum <= 0;
            baseline_count <= 0;
            baseline <= 0;
            calibration_done <= 0;
            sensor_ready <= 0;
            publish_pending <= 0;
            sent <= 0;
            last_sent <= 0;
            param_valid <= 0;
            param_value <= 0;
        end else begin
            param_valid <= 0;
            publish_pending <= accept && calibration_done;
            if (sample_error && sample_channel == 3'd0) begin
                filter_acc <= 0;
                sensor_ready <= 0;
                publish_pending <= 0;
                if (!calibration_done) begin
                    baseline_sum <= 0;
                    baseline_count <= 0;
                end
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
                    if (!calibration_done) begin
                        if (baseline_count == 5'd15) begin
                            baseline <= baseline_total[13:4];
                            baseline_sum <= 0;
                            baseline_count <= 0;
                            calibration_done <= 1;
                            sensor_ready <= 1;
                        end else begin
                            baseline_sum <= baseline_sum + ch0_data;
                            baseline_count <= baseline_count + 1'b1;
                        end
                    end else begin
                        sensor_ready <= 1;
                    end
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

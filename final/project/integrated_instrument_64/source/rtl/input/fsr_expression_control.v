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
    localparam [10:0] ADC_FULL_SCALE=FULL_SCALE[10:0];
    localparam [10:0] ADC_DEADBAND=DEADBAND[10:0];
    wire [10:0] release_threshold = {1'b0,baseline} + ADC_DEADBAND;
    assign param_id = `PARAM_MODULATION;
    // Calibrate both the offset and span. The old absolute-ADC mapping jumped
    // to baseline/full_scale as soon as the baseline gate was crossed.
    // Compute one Q8 scale at startup with a shared bit-serial divider.
    reg scaling;
    reg [4:0] scale_bits;
    reg [23:0] scale_quotient, pressure_scale;
    reg [10:0] scale_remainder, scale_divisor;
    wire [11:0] scale_trial={scale_remainder,scale_quotient[23]};
    wire scale_take=scale_trial>={1'b0,scale_divisor};
    wire [11:0] scale_next_remainder=scale_take ?
        scale_trial-{1'b0,scale_divisor} : scale_trial;
    wire [23:0] scale_next_quotient={scale_quotient[22:0],scale_take};
    wire [10:0] pressure_distance={1'b0,filtered_value}-release_threshold;
    wire [34:0] pressure_product=pressure_distance*pressure_scale;
    assign modulation_value=!sensor_ready || filtered_value<=release_threshold ?
        16'd0 : filtered_value>=FULL_SCALE ? 16'hffff :
        pressure_product[23:8];

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
            scaling<=0;scale_bits<=0;scale_quotient<=0;
            pressure_scale<=0;scale_remainder<=0;scale_divisor<=1;
        end else begin
            param_valid <= 0;
            publish_pending <= accept && sensor_ready;
            if(scaling) begin
                scale_quotient<=scale_next_quotient;
                scale_remainder<=scale_next_remainder[10:0];
                scale_bits<=scale_bits-1'b1;
                if(scale_bits==1) begin
                    pressure_scale<=scale_next_quotient;
                    scaling<=0;sensor_ready<=1;
                end
            end
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
                            // An already-loaded sensor cannot establish a
                            // usable span; hold modulation at zero in that case.
                            if(ADC_FULL_SCALE > {1'b0,baseline_total[13:4]}+ADC_DEADBAND) begin
                                scale_divisor<=ADC_FULL_SCALE-
                                    {1'b0,baseline_total[13:4]}-ADC_DEADBAND;
                                scale_quotient<=24'hffff00;
                                scale_remainder<=0;scale_bits<=24;scaling<=1;
                            end
                        end else begin
                            baseline_sum <= baseline_sum + ch0_data;
                            baseline_count <= baseline_count + 1'b1;
                        end
                    end else if(!scaling &&
                        {1'b0,ch0_data}+ADC_DEADBAND < {1'b0,baseline}) begin
                        // Recover after a loaded startup or an unloaded level
                        // lower than calibration. Never learn a pressed level
                        // upward: that would silently remove sustained vibrato.
                        baseline<=ch0_data;
                        sensor_ready<=0;
                        if(ADC_FULL_SCALE>{1'b0,ch0_data}+ADC_DEADBAND) begin
                            scale_divisor<=ADC_FULL_SCALE-{1'b0,ch0_data}-ADC_DEADBAND;
                            scale_quotient<=24'hffff00;
                            scale_remainder<=0;scale_bits<=24;scaling<=1;
                        end
                    end else if(!scaling && pressure_scale!=0) begin
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

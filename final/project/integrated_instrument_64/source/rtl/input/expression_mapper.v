// Convert a filtered MCP3008 sample into the frozen modulation interface.
// Calibration values are board-specific and should be set after measuring the
// actual FSR divider.  Fault limits are disabled unless explicitly enabled.
module expression_mapper #(
    parameter integer ZERO_LEVEL = 0,
    parameter integer FULL_SCALE = 1023,
    parameter integer DEADBAND = 0,
    parameter integer ENABLE_FAULT_CHECK = 0,
    parameter integer FAULT_LOW_LEVEL = 0,
    parameter integer FAULT_HIGH_LEVEL = 1023
) (
    input  wire [9:0]  adc_value,
    output reg  [15:0] modulation_value,
    output reg         sensor_valid,
    output reg         sensor_fault
);
    reg [31:0] scaled_value;
    integer active_zero;
    // Nonstandard calibration keeps the original 32-bit arithmetic.
    localparam integer BOUNDED=ZERO_LEVEL>=0 && DEADBAND>=0 &&
        DEADBAND<=1023 && FULL_SCALE<=1023 && FULL_SCALE>ZERO_LEVEL;
    localparam [9:0] SPAN=FULL_SCALE-ZERO_LEVEL;
    localparam [10:0] ZERO_LEVEL_W=ZERO_LEVEL;
    wire [10:0] distance_wide={1'b0,adc_value}-ZERO_LEVEL_W;
    wire [9:0] distance=distance_wide[9:0];
    wire [25:0] numerator=distance*26'd65535;
    wire [25:0] modulation_divided=numerator/SPAN;

    always @* begin
        scaled_value = 32'd0;
        sensor_fault = 1'b0;
        if (ENABLE_FAULT_CHECK != 0) begin
            if ((adc_value < FAULT_LOW_LEVEL) || (adc_value > FAULT_HIGH_LEVEL))
                sensor_fault = 1'b1;
        end
        sensor_valid = !sensor_fault;
        active_zero = ZERO_LEVEL + DEADBAND;

        if (sensor_fault || (FULL_SCALE <= ZERO_LEVEL) ||
            (adc_value <= active_zero)) begin
            modulation_value = 16'd0;
        end else if (adc_value >= FULL_SCALE) begin
            modulation_value = 16'hffff;
        end else begin
            if(BOUNDED) begin
                scaled_value={6'd0,numerator};
                modulation_value=modulation_divided[15:0];
            end else begin
                scaled_value = (adc_value - ZERO_LEVEL) * 32'd65535;
                modulation_value = scaled_value / (FULL_SCALE - ZERO_LEVEL);
            end
        end
    end
endmodule

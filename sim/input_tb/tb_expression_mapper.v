`timescale 1ns/1ps

module tb_expression_mapper;
    reg [9:0] adc_value;
    wire [15:0] modulation_value;
    wire sensor_valid, sensor_fault;

    expression_mapper #(
        .ZERO_LEVEL(100), .FULL_SCALE(900), .DEADBAND(2),
        .ENABLE_FAULT_CHECK(1), .FAULT_LOW_LEVEL(10), .FAULT_HIGH_LEVEL(1000)
    ) dut (
        .adc_value(adc_value), .modulation_value(modulation_value),
        .sensor_valid(sensor_valid), .sensor_fault(sensor_fault)
    );

    task check;
        input [9:0] value;
        input [15:0] expected;
        input expected_fault;
        begin
            adc_value = value;
            #1;
            if (modulation_value !== expected || sensor_fault !== expected_fault ||
                sensor_valid !== !expected_fault) begin
                $display("FAIL mapper adc=%0d value=%0d fault=%b", value,
                    modulation_value, sensor_fault);
                $finish;
            end
        end
    endtask

    initial begin
        check(10'd0,    16'd0,    1'b1);
        check(10'd101,  16'd0,    1'b0);
        check(10'd500,  16'd32767, 1'b0);
        check(10'd950,  16'd65535, 1'b0);
        check(10'd1023, 16'd0,     1'b1);
        $display("PASS expression mapper clamp/deadband/fault checks");
        $finish;
    end
endmodule

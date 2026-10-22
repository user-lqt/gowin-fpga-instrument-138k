`include "event_defs.vh"
// Dedicated K230 UART. This does not share a pin/parser with the BLE bridge.
// Five-byte frame: A5 CMD VALUE 00 XOR(first four bytes).
// B4: percent 0..100 in steps of 5; B5: instrument ID 0=piano/1=guitar/2=bell.
// Output is the parameter manager's UI range, NOT the audio gain payload.
module k230_control_rx #(
    parameter integer CLK_HZ = 12288000,
    parameter integer BAUD = 115200
) (
    input wire clk, rst_n, uart_rx,
    output reg param_valid,
    output reg [3:0] param_id,
    output reg [15:0] param_value,
    output wire frame_error
);
    wire command_valid, uart_error;
    wire [7:0] command, argument_a, argument_b;
    reg command_error;
    wire [14:0] scaled_volume = {7'd0, argument_a} * 15'd127 + 15'd50;
    assign frame_error = uart_error | command_error;
    ble_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) receiver (
        .clk(clk), .rst_n(rst_n), .uart_rx(uart_rx),
        .event_valid(), .event_type(), .note_id(), .velocity(),
        .song_valid(), .song_id(), .frame_error(uart_error),
        .command_valid(command_valid), .command(command),
        .argument_a(argument_a), .argument_b(argument_b)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            param_valid <= 0; param_id <= 0; param_value <= 0; command_error <= 0;
        end else begin
            param_valid <= 0; command_error <= 0;
            if (command_valid) begin
                if (command == 8'hB4 && argument_b == 0 && argument_a <= 100
                        && argument_a % 5 == 0) begin
                    param_valid <= 1;
                    param_id <= `PARAM_VOLUME;
                    param_value <= scaled_volume / 15'd100;
                end else if (command == 8'hB5 && argument_b == 0 && argument_a <= 2) begin
                    param_valid <= 1;
                    param_id <= `PARAM_INSTRUMENT;
                    param_value <= {8'd0, argument_a};
                end else command_error <= 1;
            end
        end
    end
endmodule

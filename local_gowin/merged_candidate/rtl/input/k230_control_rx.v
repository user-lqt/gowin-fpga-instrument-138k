`include "event_defs.vh"
// Dedicated K230 UART. This does not share a pin/parser with the BLE bridge.
// Five-byte frame: A5 CMD VALUE 00 XOR(first four bytes).
// B4: percent 0..100 in steps of 5; B5: instrument ID 0=piano/1=guitar/2=bell.
// 90 NOTE VEL / 80 NOTE 00: one touch note; B6 NOTE 00 renews its 1s lease.
// Output is the parameter manager's UI range, NOT the audio gain payload.
module k230_control_rx #(
    parameter integer CLK_HZ = 12288000,
    parameter integer BAUD = 115200,
    parameter integer NOTE_TIMEOUT_MS = 1000
) (
    input wire clk, rst_n, uart_rx,
    output reg param_valid,
    output reg [3:0] param_id,
    output reg [15:0] param_value,
    output wire frame_error,
    output reg event_valid,
    output reg [1:0] event_type,
    output reg [6:0] note_id,
    output reg [7:0] velocity
);
    wire command_valid, uart_error;
    wire [7:0] command, argument_a, argument_b;
    reg command_error;
    // Monophonic touch source. B6 NOTE 00 renews a held note without retrigger.
    // If Python stops or the cable disconnects, release after the lease expires.
    localparam integer LEASE_CYCLES = (CLK_HZ / 1000) * NOTE_TIMEOUT_MS;
    localparam integer AGE_BITS = LEASE_CYCLES > 1 ? $clog2(LEASE_CYCLES + 1) : 1;
    reg [AGE_BITS-1:0] note_age;
    reg held, pending_on;
    reg [6:0] held_note, pending_note;
    reg [7:0] pending_velocity;
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
            event_valid <= 0; event_type <= `EVENT_NONE; note_id <= 0; velocity <= 0;
            held <= 0; held_note <= 0; note_age <= 0;
            pending_on <= 0; pending_note <= 0; pending_velocity <= 0;
        end else begin
            param_valid <= 0; command_error <= 0;
            event_valid <= 0;
            if (held) begin
                if (note_age >= LEASE_CYCLES - 1) begin
                    event_valid <= 1; event_type <= `EVENT_NOTE_OFF;
                    note_id <= held_note; velocity <= 0; held <= 0; note_age <= 0;
                end else note_age <= note_age + 1'b1;
            end
            if (pending_on) begin
                pending_on <= 0; held <= 1; held_note <= pending_note; note_age <= 0;
                event_valid <= 1; event_type <= `EVENT_NOTE_ON;
                note_id <= pending_note; velocity <= pending_velocity;
            end
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
                end else if ((command == 8'h90 || command == 8'h80)
                             && argument_a < 128 && argument_b < 128) begin
                    if (command == 8'h90 && argument_b != 0) begin
                        note_age <= 0; held <= 1; held_note <= argument_a[6:0];
                        event_valid <= 1;
                        if (held && held_note != argument_a[6:0]) begin
                            // Recover even if the preceding NOTE_OFF was lost.
                            event_type <= `EVENT_NOTE_OFF; note_id <= held_note; velocity <= 0;
                            pending_on <= 1; pending_note <= argument_a[6:0]; pending_velocity <= argument_b;
                        end else begin
                            event_type <= `EVENT_NOTE_ON; note_id <= argument_a[6:0]; velocity <= argument_b;
                        end
                    end else if (held && held_note == argument_a[6:0]) begin
                        event_valid <= 1; event_type <= `EVENT_NOTE_OFF;
                        note_id <= held_note; velocity <= 0; held <= 0; note_age <= 0;
                    end
                end else if (command == 8'hB6 && argument_a < 128 && argument_b == 0) begin
                    if (held && held_note == argument_a[6:0]) begin
                        note_age <= 0; held <= 1;
                        event_valid <= 0; // A renewal on the deadline wins over timeout.
                    end
                end else command_error <= 1;
            end
        end
    end
endmodule

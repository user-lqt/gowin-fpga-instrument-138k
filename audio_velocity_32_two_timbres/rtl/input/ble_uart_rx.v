`include "event_defs.vh"
// 115200 8-N-1 receiver and small command parser for the ESP32-C3 BLE bridge.
// Frame: A5 CMD NOTE VELOCITY CHECKSUM, where checksum=A5^CMD^NOTE^VELOCITY.
// CMD 90 = NOTE_ON, 80 = NOTE_OFF. Invalid frames are discarded.
module ble_uart_rx #(
    parameter integer CLK_HZ=12288000,
    parameter integer BAUD=115200
) (
    input wire clk, input wire rst_n, input wire uart_rx,
    output reg event_valid, output reg [1:0] event_type,
    output reg [6:0] note_id, output reg [7:0] velocity,
    output reg frame_error
);
    localparam integer CLKS_PER_BIT=(CLK_HZ+BAUD/2)/BAUD;
    localparam integer HALF_BIT=CLKS_PER_BIT/2;
    reg rx_meta,rx_sync,active;
    reg [15:0] baud_count;
    reg [3:0] bit_count;
    reg [7:0] byte_shift,rx_byte;
    reg byte_valid;
    reg [2:0] parser_state;
    reg [7:0] cmd_reg,note_reg,velocity_reg;
    reg [7:0] checksum_reg;
    localparam WAIT_SOF=0,WAIT_CMD=1,WAIT_NOTE=2,WAIT_VEL=3,WAIT_SUM=4;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            rx_meta<=1;rx_sync<=1;active<=0;baud_count<=0;bit_count<=0;
            byte_shift<=0;rx_byte<=0;byte_valid<=0;
        end else begin
            rx_meta<=uart_rx;rx_sync<=rx_meta;byte_valid<=0;
            if(!active) begin
                if(!rx_sync) begin active<=1;baud_count<=HALF_BIT;bit_count<=0;end
            end else if(baud_count==0) begin
                baud_count<=CLKS_PER_BIT-1;
                if(bit_count==0) begin
                    if(rx_sync) begin active<=0;end
                    else bit_count<=1;
                end else if(bit_count<=8) begin
                    byte_shift[bit_count-1]<=rx_sync;bit_count<=bit_count+1'b1;
                end else begin
                    active<=0;bit_count<=0;
                    if(rx_sync) begin rx_byte<=byte_shift;byte_valid<=1;end
                end
            end else baud_count<=baud_count-1'b1;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin parser_state<=WAIT_SOF;cmd_reg<=0;note_reg<=0;velocity_reg<=0;
            checksum_reg<=0;event_valid<=0;event_type<=`EVENT_NONE;note_id<=0;velocity<=0;frame_error<=0;
        end else begin
            event_valid<=0;frame_error<=0;
            if(byte_valid) case(parser_state)
                WAIT_SOF: if(rx_byte==8'hA5) parser_state<=WAIT_CMD;
                WAIT_CMD: begin cmd_reg<=rx_byte;checksum_reg<=8'hA5^rx_byte;parser_state<=WAIT_NOTE;end
                WAIT_NOTE: begin note_reg<=rx_byte;checksum_reg<=checksum_reg^rx_byte;parser_state<=WAIT_VEL;end
                WAIT_VEL: begin velocity_reg<=rx_byte;checksum_reg<=checksum_reg^rx_byte;parser_state<=WAIT_SUM;end
                WAIT_SUM: begin
                    parser_state<=WAIT_SOF;
                    if(rx_byte==checksum_reg) begin
                        if(cmd_reg==8'h90 || cmd_reg==8'h80) begin
                            event_valid<=1; event_type<=cmd_reg==8'h90 ? `EVENT_NOTE_ON : `EVENT_NOTE_OFF;
                            note_id<=note_reg[6:0]; velocity<=cmd_reg==8'h90 ? velocity_reg : 0;
                        end else frame_error<=1;
                    end else frame_error<=1;
                end
                default: parser_state<=WAIT_SOF;
            endcase
        end
    end
endmodule

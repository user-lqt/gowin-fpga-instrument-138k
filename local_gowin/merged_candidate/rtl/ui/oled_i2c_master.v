`timescale 1ns/1ps
// Byte streaming master. First byte includes the address; last requests STOP.
// Both wires are open drain. ACK/stretch failure terminates the transaction.
module oled_i2c_master #(
    parameter integer CLK_HZ = 12288136,
    parameter integer I2C_HZ = 100000,
    parameter integer TIMEOUT_TICKS = 2000,
    // Vendor comparison only: still release SDA and record NACK, but continue.
    parameter integer IGNORE_NACK = 0
) (
    input wire clk, rst_n, send, last,
    input wire [7:0] data,
    output wire ready,
    output reg done, error,
    output reg nack_seen,
    inout wire scl, sda
);
    localparam integer DIV = (CLK_HZ + 4*I2C_HZ - 1)/(4*I2C_HZ);
    localparam IDLE=0, START_WAIT=1, START_HOLD=2, START_LOW=3,
        BIT_LOW=4, BIT_RISE=5, BIT_HIGH=6, BIT_FALL=7,
        ACK_LOW=8, ACK_RISE=9, ACK_HIGH=10, ACK_FALL=11,
        STOP_LOW=12, STOP_RISE=13, STOP_HIGH=14, STOP_RELEASE=15,
        START_HOLD_EXTRA=16, STOP_HOLD_EXTRA=17,
        BIT_HOLD_EXTRA=18, ACK_HOLD_EXTRA=19;
    reg [4:0] state;
    reg scl_low, sda_low, transaction, final_byte;
    reg [7:0] shift;
    reg [2:0] bit_index;
    reg [31:0] divider, waited;
    reg [1:0] scl_sync, sda_sync;
    assign scl = scl_low ? 1'b0 : 1'bz;
    assign sda = sda_low ? 1'b0 : 1'bz;
    assign ready = (state == IDLE);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin scl_sync <= 3; sda_sync <= 3; end
        else begin scl_sync <= {scl_sync[0], scl}; sda_sync <= {sda_sync[0], sda}; end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; scl_low<=0; sda_low<=0; transaction<=0;
            final_byte<=0; shift<=0; bit_index<=7; divider<=0;
            waited<=0; done<=0; error<=0; nack_seen<=0;
        end else begin
            done<=0;
            if (state == IDLE) begin
                divider<=0; waited<=0;
                if (send) begin
                    shift<=data; bit_index<=7; final_byte<=last; error<=0;
                    state<=transaction ? BIT_LOW : START_WAIT;
                end
            end else if (divider == DIV-1) begin
                divider<=0;
                // Sample only after the released clock has reached the pin.
                if ((state==START_WAIT && (!scl_sync[1] || !sda_sync[1])) ||
                    ((state==BIT_HIGH || state==ACK_HIGH || state==STOP_HIGH) && !scl_sync[1])) begin
                    if (waited == TIMEOUT_TICKS-1) begin
                        scl_low<=0; sda_low<=0; transaction<=0;
                        state<=IDLE; done<=1; error<=1; waited<=0;
                    end else waited<=waited+1'b1;
                end else begin
                    waited<=0;
                    case (state)
                        START_WAIT: begin sda_low<=1; state<=START_HOLD; end
                        START_HOLD: state<=START_HOLD_EXTRA;
                        START_HOLD_EXTRA: begin scl_low<=1; transaction<=1; state<=START_LOW; end
                        START_LOW: state<=BIT_LOW;
                        BIT_LOW: begin sda_low<=!shift[bit_index]; state<=BIT_RISE; end
                        BIT_RISE: begin scl_low<=0; state<=BIT_HIGH; end
                        BIT_HIGH: state<=BIT_HOLD_EXTRA;
                        BIT_HOLD_EXTRA: state<=BIT_FALL;
                        BIT_FALL: begin
                            scl_low<=1;
                            if (bit_index==0) state<=ACK_LOW;
                            else begin bit_index<=bit_index-1'b1; state<=BIT_LOW; end
                        end
                        ACK_LOW: begin sda_low<=0; state<=ACK_RISE; end
                        ACK_RISE: begin scl_low<=0; state<=ACK_HIGH; end
                        ACK_HIGH: begin
                            if (sda_sync[1]) nack_seen<=1;
                            error<=sda_sync[1] && !IGNORE_NACK;
                            state<=ACK_HOLD_EXTRA;
                        end
                        ACK_HOLD_EXTRA: state<=ACK_FALL;
                        ACK_FALL: begin
                            scl_low<=1;
                            if (final_byte || error) state<=STOP_LOW;
                            else begin state<=IDLE; done<=1; end
                        end
                        STOP_LOW: begin sda_low<=1; state<=STOP_RISE; end
                        STOP_RISE: begin scl_low<=0; state<=STOP_HIGH; end
                        STOP_HIGH: state<=STOP_HOLD_EXTRA;
                        STOP_HOLD_EXTRA: begin sda_low<=0; state<=STOP_RELEASE; end
                        STOP_RELEASE: begin state<=IDLE; transaction<=0; done<=1; end
                        default: begin state<=IDLE; scl_low<=0; sda_low<=0; transaction<=0; end
                    endcase
                end
            end else divider<=divider+1'b1;
        end
    end
endmodule

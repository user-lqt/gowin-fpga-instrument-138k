`timescale 1ns/1ps
// Diagnostic only. Reference: supplied STM32F103C8T6 IIC OLED_Init.
// Each command/argument gets START,78,00,byte,STOP, like OLED_WR_Byte.
// A5 replaces A4 so no framebuffer is needed. No retry or traffic after AF.
module oled_vendor_probe #(
    parameter integer CLK_HZ=50000000,
    parameter integer POWERUP_CYCLES=CLK_HZ/2,
    parameter integer TIMEOUT_TICKS=2000
) (
    input wire clk, rst_n,
    inout wire scl, sda,
    output reg finished, failed,
    output wire nack_seen
);
    reg [31:0] delay_count;
    reg [4:0] command_index;
    reg [1:0] byte_index;
    reg started, outstanding;
    wire ready, done, error;
    wire send=started && !finished && !failed && !outstanding && ready;
    wire [7:0] value=byte_index==0 ? 8'h78 :
        byte_index==1 ? 8'h00 : command_byte(command_index);
    oled_i2c_master #(.CLK_HZ(CLK_HZ), .I2C_HZ(50000),
        .TIMEOUT_TICKS(TIMEOUT_TICKS), .IGNORE_NACK(1)) bus (
        .clk(clk), .rst_n(rst_n), .send(send), .last(byte_index==2),
        .data(value), .ready(ready), .done(done), .error(error),
        .nack_seen(nack_seen), .scl(scl), .sda(sda)
    );
    function [7:0] command_byte;
        input [4:0] n;
        begin
            case(n)
                0:command_byte=8'hae; 1:command_byte=8'h00;
                2:command_byte=8'h10; 3:command_byte=8'h40;
                4:command_byte=8'h81; 5:command_byte=8'hcf;
                6:command_byte=8'ha1; 7:command_byte=8'hc8;
                8:command_byte=8'ha6; 9:command_byte=8'ha8;
                10:command_byte=8'h3f; 11:command_byte=8'hd3;
                12:command_byte=8'h00; 13:command_byte=8'hd5;
                14:command_byte=8'h80; 15:command_byte=8'hd9;
                16:command_byte=8'hf1; 17:command_byte=8'hda;
                18:command_byte=8'h12; 19:command_byte=8'hdb;
                20:command_byte=8'h40; 21:command_byte=8'h20;
                22:command_byte=8'h02; 23:command_byte=8'h8d;
                24:command_byte=8'h14; 25:command_byte=8'ha5;
                26:command_byte=8'ha6; default:command_byte=8'haf;
            endcase
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            delay_count<=0; command_index<=0; byte_index<=0;
            started<=0; outstanding<=0; finished<=0; failed<=0;
        end else begin
            if(!started) begin
                if(delay_count==POWERUP_CYCLES-1) started<=1;
                else delay_count<=delay_count+1'b1;
            end
            if(send) outstanding<=1;
            if(done) begin
                outstanding<=0;
                if(error) failed<=1; // Clock/bus timeout still stops safely.
                else if(byte_index==2) begin
                    byte_index<=0;
                    if(command_index==27) finished<=1;
                    else command_index<=command_index+1'b1;
                end else byte_index<=byte_index+1'b1;
            end
        end
    end
endmodule

`timescale 1ns/1ps
module oled_vendor_probe_case #(parameter ACK=1)(output reg passed=0);
    reg clk=0, rst_n=0;
    always #50 clk=~clk;
    tri1 scl,sda;
    reg ack_low=0, active=0;
    integer bits=0, bytes=0, transactions=0, commands=0;
    reg [7:0] rx=0;
    wire finished, failed, nack_seen;
    // From supplied STM32F103C8T6 IIC OLED_Init (A4 -> A5 diagnostic).
    localparam [223:0] EXPECTED=224'hae00104081cfa1c8a6a83fd300d580d9f1da12db4020028d14a5a6af;
    oled_vendor_probe #(.CLK_HZ(10000000), .POWERUP_CYCLES(50)) dut (
        .clk(clk), .rst_n(rst_n), .scl(scl), .sda(sda),
        .finished(finished), .failed(failed), .nack_seen(nack_seen)
    );
    assign sda=ack_low ? 1'b0 : 1'bz;
    always @(negedge sda) if(scl===1) begin
        if(active) $fatal(1,"unexpected repeated START");
        active=1; bits=0; bytes=0;
    end
    always @(posedge sda) if(scl===1 && active) begin
        if(bytes!=3) $fatal(1,"vendor transaction must contain 3 bytes, got %0d",bytes);
        active=0; transactions=transactions+1;
    end
    always @(negedge scl) ack_low=active && bits==8 && ACK;
    always @(posedge scl) if(active) begin
        if(bits==8) bits=0;
        else begin
            rx={rx[6:0],sda}; bits=bits+1;
            if(bits==8) begin
                if(bytes==0 && rx!==8'h78) $fatal(1,"wrong address");
                if(bytes==1 && rx!==0) $fatal(1,"wrong control");
                if(bytes==2) begin
                    if(commands>=28 || rx!==EXPECTED[223-8*commands -: 8])
                        $fatal(1,"vendor command %0d mismatch: %h",commands,rx);
                    commands=commands+1;
                end
                bytes=bytes+1;
            end
        end
    end
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        wait(finished);
        if(failed || nack_seen!==!ACK || commands!=28 || transactions!=28)
            $fatal(1,"incorrect completion / ACK reporting");
        #1000000;
        if(transactions!=28 || scl!==1 || sda!==1) $fatal(1,"bus not idle after AF");
        passed=1;
    end
endmodule

module tb_oled_vendor_probe;
    wire ack_pass, noack_pass;
    oled_vendor_probe_case #(.ACK(1)) with_ack(ack_pass);
    oled_vendor_probe_case #(.ACK(0)) without_ack(noack_pass);
    reg clk=0,rst_n=0;
    always #50 clk=~clk;
    tri1 stuck_scl, stuck_sda;
    assign stuck_scl=0;
    wire finished,failed,nack_seen;
    oled_vendor_probe #(.CLK_HZ(10000000), .POWERUP_CYCLES(50), .TIMEOUT_TICKS(20)) stuck (
        .clk(clk), .rst_n(rst_n), .scl(stuck_scl), .sda(stuck_sda),
        .finished(finished), .failed(failed), .nack_seen(nack_seen)
    );
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        wait(ack_pass && noack_pass);
        if(!failed || finished || stuck_sda!==1) $fatal(1,"stuck bus must fail and release SDA");
        $display("PASS vendor 28 command transactions with ACK and without ACK; idle after AF; stuck bus timeout");
        $finish;
    end
    initial begin #50000000; $fatal(1,"probe timeout"); end
endmodule

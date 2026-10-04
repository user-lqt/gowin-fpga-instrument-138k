`timescale 1ns/1ps
module tb_oled_i2c_timing;
    reg clk=0;
    always #50 clk=~clk;
    reg rst_n=0, send=0, last=0;
    reg [7:0] data=0;
    tri1 scl, sda;
    reg ack=0, active=0, first_fall=0;
    integer bits=0, stops=0;
    realtime start_at=0, rise_at=0, fall_at=0, stop_at=0;
    wire ready, done, error;
    assign sda=ack ? 1'b0 : 1'bz;
    oled_i2c_master #(.CLK_HZ(10000000), .I2C_HZ(100000)) dut (
        .clk(clk), .rst_n(rst_n), .send(send), .last(last), .data(data),
        .ready(ready), .done(done), .error(error), .nack_seen(), .scl(scl), .sda(sda)
    );
    always @(negedge sda) if (scl===1) begin
        if (stops>0 && $realtime-stop_at<4700) $fatal(1,"I2C tBUF below 4.7 us");
        active=1; first_fall=1; start_at=$realtime; bits=0;
    end
    always @(posedge sda) if (scl===1 && active) begin
        if ($realtime-rise_at<4000) $fatal(1,"I2C tSU:STO below 4 us");
        active=0; stop_at=$realtime; stops=stops+1;
    end
    always @(negedge scl) if (active) begin
        if (first_fall) begin
            if ($realtime-start_at<4000) $fatal(1,"I2C tHD:STA below 4 us");
            first_fall=0;
        end else if ($realtime-rise_at<4000) $fatal(1,"I2C tHIGH below 4 us");
        fall_at=$realtime;
        ack=(bits==8);
    end else ack=0;
    always @(posedge scl) if (active) begin
        if ($realtime-fall_at<4700) $fatal(1,"I2C tLOW below 4.7 us");
        rise_at=$realtime;
        if (bits==8) bits=0; else bits=bits+1;
    end
    task transmit;
        input [7:0] value;
        input is_last;
        begin
            wait(ready); @(negedge clk); data=value; last=is_last; send=1;
            @(negedge clk); send=0;
            wait(done); if (error) $fatal(1,"unexpected NACK");
            @(negedge clk);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        transmit(8'h78,0); transmit(0,0); transmit(8'hae,1);
        transmit(8'h78,0); transmit(0,0); transmit(8'haf,1);
        if (stops!=2) $fatal(1,"missing STOP");
        $display("PASS I2C standard-mode START/STOP hold, bus free, high and low timing at 100 kHz divider");
        $finish;
    end
    initial begin #2000000; $fatal(1,"I2C timing test timeout"); end
endmodule

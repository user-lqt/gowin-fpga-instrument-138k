`timescale 1ns/1ps
module tb_encoder_b_input;
    reg clk=0,rst_n=0,a=1,b=1,sw=1;
    always #40 clk=~clk;
    wire up,down,press,ready;
    integer ups=0,downs=0,presses=0;
    encoder_b_input #(.FILTER_CYCLES(2500),.BUTTON_CYCLES(100)) dut (
        .clk(clk),.rst_n(rst_n),.enc_a(a),.enc_b(b),.enc_sw_n(sw),
        .step_up(up),.step_down(down),.press(press),.input_ready(ready)
    );
    always @(posedge clk) begin
        if(up) ups=ups+1;
        if(down) downs=downs+1;
        if(press) presses=presses+1;
    end
    task phase;
        input [1:0] ab;
        begin {a,b}=ab; repeat(2700) @(negedge clk); end
    endtask
    initial begin
        repeat(5) @(negedge clk); rst_n=1; wait(ready); phase(2'b11);
        phase(2'b10);phase(2'b00);phase(2'b01);phase(2'b11);
        if(ups!=1 || downs!=0) $fatal(1,"EC11_B CW decode failed");
        phase(2'b01);phase(2'b00);phase(2'b10);phase(2'b11);
        if(ups!=1 || downs!=1) $fatal(1,"EC11_B CCW decode failed");
        sw=0;repeat(10) @(negedge clk);sw=1;repeat(10) @(negedge clk);
        sw=0;repeat(300) @(negedge clk);
        if(presses!=1) $fatal(1,"EC11_B bounce or hold repeated");
        sw=1;repeat(120) @(negedge clk);sw=0;repeat(120) @(negedge clk);
        if(presses!=2) $fatal(1,"EC11_B release/rearm failed");
        $display("PASS EC11_B input CW/CCW, debounce, hold and rearm");$finish;
    end
    initial begin #10000000;$fatal(1,"EC11_B input timeout");end
endmodule

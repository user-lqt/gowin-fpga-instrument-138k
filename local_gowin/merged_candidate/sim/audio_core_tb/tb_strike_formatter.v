`timescale 1ns/1ps
module tb_strike_formatter;
    reg clk=0,rst_n=0;
    reg [31:0] debug_value=0;
    reg [15:0] frames=0;
    wire [40:0] value;
    always #5 clk=~clk;
    strike_display_formatter dut(.clk(clk),.rst_n(rst_n),
        .debug_value(debug_value),.frames(frames),.display_value(value));
    task check;
        input [15:0] count;
        input [4:0] key;
        input [7:0] velocity;
        input [39:0] expected;
        begin
            @(negedge clk);
            frames=count;debug_value={1'b1,2'b11,key,velocity,16'd0};
            repeat(count+25) @(negedge clk);
            if(value!=={1'b1,expected}) $fatal(1,"format %h expected %h",value,expected);
            debug_value[30:29]=0;
            repeat(30) @(negedge clk);
            if(value!=={1'b1,expected}) $fatal(1,"release retention");
        end
    endtask
    initial begin
        #1;rst_n=0;repeat(3) @(negedge clk);
        if(value!==0) $fatal(1,"reset");
        rst_n=1;
        check(50,0,127,40'h0112700100);
        check(150,23,16,40'h2401600300);
        check(5004,23,16,40'h2401610001);
        check(1,0,127,40'h0112700002);
        check(0,0,127,40'h0112700000);
        $display("PASS serial calibration formatter and release retention");
        $finish;
    end
endmodule

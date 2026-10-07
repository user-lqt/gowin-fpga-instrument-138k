`timescale 1ns/1ps
module tb_encoder_param_queue;
    reg clk=0,rst_n=0,tick=0,av=0,bv=0,cv=0,dv=0;
    always #5 clk=~clk;
    reg [3:0] ai=0,bi=1;
    reg [15:0] ad=0,bd=0,cd=0,dd=0;
    wire valid,overflow;
    wire [3:0] id;
    wire [15:0] value;
    integer i;
    encoder_param_queue dut(.clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .a_valid(av),.b_valid(bv),.c_valid(cv),.d_valid(dv),
        .a_id(ai),.b_id(bi),.c_id(4'd2),.d_id(4'd3),
        .a_value(ad),.b_value(bd),.c_value(cd),.d_value(dd),
        .valid(valid),.id(id),.value(value),.overflow(overflow));
    task consume;
        input [15:0] expected;
        begin
            @(negedge clk);tick=1;#1;
            if(!valid || value!=expected) $fatal(1,"queue order/value mismatch");
            @(negedge clk);tick=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        for(i=0;i<4;i=i+1) begin
            av=1;bv=1;ad=i*2;bd=i*2+1;@(negedge clk);
        end
        av=0;bv=0;
        // Full queue can accept exactly one event when one is popped.
        tick=1;av=1;ad=8;#1;
        if(!valid || value!=0) $fatal(1,"full queue pop failed");
        @(negedge clk);tick=0;av=0;
        for(i=1;i<=8;i=i+1) consume(i);
        if(overflow || dut.count!=0) $fatal(1,"wrap/full replacement failed");
        // Both encoders, joystick X and FSR can publish simultaneously.
        av=1;bv=1;cv=1;dv=1;ad=10;bd=11;cd=12;dd=13;
        @(negedge clk);ad=14;bd=15;cd=16;dd=17;
        @(negedge clk);av=0;bv=0;cv=0;dv=0;
        for(i=10;i<=17;i=i+1) consume(i);
        if(overflow || dut.count!=0) $fatal(1,"four-producer ordering/wrap failed");
        for(i=0;i<4;i=i+1) begin av=1;bv=1;ad=i*2;bd=i*2+1;@(negedge clk);end
        av=1;bv=1;@(negedge clk);av=0;bv=0;
        if(!overflow || dut.count!=8) $fatal(1,"overflow not detected");
        rst_n=0;@(negedge clk);
        if(overflow || valid) $fatal(1,"reset failed");
        $display("PASS four-producer queue ordering, wrap, full/pop, overflow and reset");$finish;
    end
endmodule

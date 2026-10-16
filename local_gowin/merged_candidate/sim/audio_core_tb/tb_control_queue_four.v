`timescale 1ns/1ps
module tb_control_queue_four;
    reg clk=0,rst_n=0,tick=0;
    reg [3:0] push=0;
    wire valid,overflow;
    wire [3:0] id;
    wire [15:0] value;
    always #5 clk=~clk;
    encoder_param_queue dut(.clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .a_valid(push[0]),.a_id(4'd0),.a_value(16'd10),
        .b_valid(push[1]),.b_id(4'd1),.b_value(16'd11),
        .c_valid(push[2]),.c_id(4'd2),.c_value(16'd12),
        .d_valid(push[3]),.d_id(4'd3),.d_value(16'd13),
        .valid(valid),.id(id),.value(value),.overflow(overflow));
    integer i;
    task emit_four;
        begin
            @(negedge clk);push=15;
            @(negedge clk);push=0;
        end
    endtask
    initial begin
        #1;repeat(3) @(negedge clk);rst_n=1;
        emit_four;emit_four;
        if(overflow) $fatal(1,"eight entries must fit");
        for(i=0;i<8;i=i+1) begin
            @(negedge clk);tick=1;#1;
            if(!valid || id!==(i%4) || value!==(10+i%4))
                $fatal(1,"four-source ordering");
            @(negedge clk);tick=0;
        end
        if(dut.count!==0) $fatal(1,"drain");
        // Full FIFO, simultaneous pop and four pushes: exactly one fits.
        emit_four;emit_four;
        @(negedge clk);tick=1;push=15;
        @(negedge clk);tick=0;push=0;
        if(!overflow || dut.count!==8) $fatal(1,"overflow/full-pop accounting");
        $display("PASS four-source parameter queue ordering, capacity and overflow");
        $finish;
    end
endmodule

`timescale 1ns/1ps
module tb_fsr_expression_control;
    reg clk=0, rst_n=0, sample_valid=0;
    reg [2:0] channel=0;
    reg [9:0] raw=0;
    wire valid, ready;
    wire [3:0] id;
    wire [15:0] value, modulation;
    wire [9:0] filtered;
    integer n, updates=0, saved_updates;
    fsr_expression_control dut (
        .clk(clk),.rst_n(rst_n),.sample_valid(sample_valid),
        .sample_channel(channel),.ch0_data(raw),.param_valid(valid),
        .param_id(id),.param_value(value),.filtered_value(filtered),
        .modulation_value(modulation),.sensor_ready(ready)
    );
    always #5 clk=~clk;
    always @(posedge clk) if (valid) begin
        updates=updates+1;
        if(id!==3 || (^value)===1'bx) $fatal(1,"invalid FSR parameter");
    end
    task sample;
        input [2:0] ch;
        input [9:0] adc;
        begin
            @(negedge clk);channel=ch;raw=adc;sample_valid=1;
            @(negedge clk);sample_valid=0;
            repeat(5) @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        if(ready || valid) $fatal(1,"FSR active before first CH0 sample");
        sample(0,561);
        if(!ready || filtered!=561 || value!=0 || updates!=1)
            $fatal(1,"FSR first-sample initialization");
        sample(1,1023);sample(2,1023);
        if(filtered!=561 || updates!=1) $fatal(1,"other ADC channels changed FSR");
        for(n=0;n<80;n=n+1) sample(0,578);
        if(filtered!=578 || modulation!=0 || updates!=1) $fatal(1,"FSR deadband");
        for(n=0;n<80;n=n+1) sample(0,758);
        if(filtered!=758 || modulation<32700 || modulation>33000)
            $fatal(1,"FSR midpoint mapping/filter convergence");
        for(n=0;n<80;n=n+1) sample(0,1023);
        if(filtered!=1023 || value!=65535) $fatal(1,"FSR full-scale saturation");
        saved_updates=updates;
        for(n=0;n<8;n=n+1) sample(0,1023);
        if(updates!=saved_updates) $fatal(1,"unchanged FSR flooded parameter queue");
        for(n=0;n<100;n=n+1) sample(0,0);
        if(filtered!=0 || value!=0) $fatal(1,"FSR negative filter step/low saturation");
        rst_n=0;@(negedge clk);
        if(ready || valid || value!=0) $fatal(1,"FSR reset");
        $display("PASS FSR CH0 filtering, deadband, mapping, saturation, update suppression and reset");
        $finish;
    end
    initial begin #100000;$fatal(1,"FSR test timeout");end
endmodule

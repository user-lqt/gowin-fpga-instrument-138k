`timescale 1ns/1ps
module tb_joystick_control;
    reg clk=0,rst_n=0,valid=0;
    reg [2:0] channel=0;
    reg [9:0] x=512,y=512;
    wire pv; wire [3:0] id; wire [15:0] value;
    wire signed [15:0] bend; wire [15:0] mod;
    joystick_control #(.DEADZONE(10'd32)) dut(
        .clk(clk),.rst_n(rst_n),.sample_valid(valid),.sample_channel(channel),
        .ch1_x(x),.ch2_y(y),.param_valid(pv),.param_id(id),.param_value(value),
        .pitch_bend(bend),.modulation(mod),.filtered_x(),.filtered_y());
    always #5 clk=~clk;
    task sample;
        input [2:0] ch; input [9:0] xv,yv;
        begin channel=ch;x=xv;y=yv;@(negedge clk);valid=1;@(negedge clk);valid=0;end
    endtask
    integer i;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        for(i=0;i<4;i=i+1) sample(1,512,512);
        if(bend!==0 || mod!==0) $fatal(1,"joystick center/deadzone failed");
        for(i=0;i<4;i=i+1) sample(1,900,512);
        sample(1,900,512);
        if(bend<=0 || id!==2) $fatal(1,"joystick positive bend failed");
        for(i=0;i<4;i=i+1) sample(2,512,900);
        sample(2,512,900);
        if(mod==0 || id!==3) $fatal(1,"joystick modulation failed");
        for(i=0;i<4;i=i+1) sample(1,100,512);
        sample(1,100,512);
        if(bend>=0 || id!==2) $fatal(1,"joystick negative bend failed");
        $display("PASS joystick averaging, center deadzone, signed bend and modulation mapping");$finish;
    end
    initial begin #100000;$fatal(1,"joystick timeout");end
endmodule

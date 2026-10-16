`timescale 1ns/1ps
module tb_bell_paths;
    reg clk=0,rst_n=0,tick=0,on=0;
    always #5 clk=~clk;
    reg [31:0] fc=32'd46819660;
    reg [7:0] velocity=127;
    wire [15:0] fixed_private,fixed_ram,live_private,live_ram;
    bianzhong fixed_voice(.clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .note_on(on),.fc(fc),.velocity(velocity),.wave(fixed_private));
    bianzhong_ram_bank #(.LANES(1)) fixed_bank(.clk(clk),.rst_n(rst_n),
        .sample_tick(tick),.note_on(on),.fcs(fc),.velocities(velocity),.waves(fixed_ram));
    bianzhong #(.DYNAMIC_PITCH(1)) live_voice(.clk(clk),.rst_n(rst_n),
        .sample_tick(tick),.note_on(on),.fc(fc),.velocity(velocity),.wave(live_private));
    bianzhong_ram_bank #(.LANES(1),.DYNAMIC_PITCH(1)) live_bank(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),.note_on(on),.fcs(fc),
        .velocities(velocity),.waves(live_ram));
    integer n,age=0;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        for(n=0;n<4096;n=n+1) begin
            @(negedge clk);tick=1;
            @(negedge clk);tick=0;on=n%1024==0;
            if(on) begin
                velocity=n==0 ? 127 : n==1024 ? 24 : n==2048 ? 80 : 110;
                age=0;
            end
            if(n%128==64) fc=fc+32'd100000;
            @(negedge clk);on=0;
            repeat(37) @(negedge clk);
            // Private precomputes its increments during the strike frame;
            // the RAM path starts mode evolution on the following frame.
            if(age>1 && (fixed_private!==fixed_ram || live_private!==live_ram))
                $fatal(1,"bell path mismatch sample=%0d fixed=%0d/%0d live=%0d/%0d",
                    n,$signed(fixed_private),$signed(fixed_ram),
                    $signed(live_private),$signed(live_ram));
            age=age+1;
        end
        $display("PASS bell private/RAM exact samples, four velocities, retrigger and dynamic pitch");
        $finish;
    end
endmodule

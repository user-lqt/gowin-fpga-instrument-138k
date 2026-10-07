`timescale 1ns/1ps
`include "event_defs.vh"
module tb_joystick_control;
    reg clk=0,rst_n=0,valid=0,error=0;
    reg [2:0] channel=0;
    reg [9:0] x=512,y=512;
    wire pv; wire [3:0] id; wire [15:0] value;
    wire signed [15:0] bend; wire [15:0] mod;
    wire [9:0] fx,fy;
    joystick_control #(.DEADZONE(10'd32)) dut(
        .clk(clk),.rst_n(rst_n),.sample_valid(valid),.sample_channel(channel),
        .sample_error(error),
        .ch1_x(x),.ch2_y(y),.param_valid(pv),.param_id(id),.param_value(value),
        .pitch_bend(bend),.modulation(mod),.filtered_x(fx),.filtered_y(fy));
    wire signed [15:0] calibrated_bend;
    wire [15:0] calibrated_mod;
    joystick_control #(.CENTER_X(10'd480),.CENTER_Y(10'd530)) calibrated(
        .clk(clk),.rst_n(rst_n),.sample_valid(valid),.sample_channel(channel),
        .sample_error(error),.ch1_x(x),.ch2_y(y),.param_valid(),.param_id(),
        .param_value(),.pitch_bend(calibrated_bend),.modulation(calibrated_mod),
        .filtered_x(),.filtered_y());
    always #5 clk=~clk;
    task sample;
        input [2:0] ch; input [9:0] xv,yv;
        begin
            @(negedge clk);channel=ch;x=xv;y=yv;valid=1;
            @(negedge clk);valid=0;
        end
    endtask
    task batch;
        input [2:0] ch; input [9:0] raw;
        integer j;
        begin
            for(j=0;j<4;j=j+1) begin
                sample(ch,raw,raw);
                if(pv !== (j==3)) $fatal(1,"event before complete average / missing event");
            end
            if(ch==1 && (id!==`PARAM_PITCH_BEND || value!==bend))
                $fatal(1,"X event has wrong ID or stale payload");
            if(ch==2 && (id!==`PARAM_MODULATION || value!==mod))
                $fatal(1,"Y event has wrong ID or stale payload");
            @(negedge clk);
            if(pv!==0) $fatal(1,"parameter event lasted more than one clock");
        end
    endtask
    task failed_sample;
        input [2:0] ch;
        begin
            @(negedge clk);channel=ch;error=1;
            @(negedge clk);error=0;
        end
    endtask
    integer i;
    integer previous;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        if(bend!==0 || mod!==0 || pv!==0) $fatal(1,"reset not neutral");
        batch(1,512);batch(2,512);
        if(bend!==0 || mod!==0 || fx!==512 || fy!==512)
            $fatal(1,"center not neutral");
        batch(1,480);if(bend!==0 || calibrated_bend!==0) $fatal(1,"lower deadzone boundary");
        batch(1,544);if(bend!==0) $fatal(1,"upper deadzone boundary");
        batch(1,479);if(bend>=0 || bend < -32) $fatal(1,"jump at negative deadzone boundary");
        batch(1,545);if(bend<=0 || bend > 32) $fatal(1,"jump at positive deadzone boundary");
        batch(1,0);
        if(bend!==-16'sd8192 || calibrated_bend!==-16'sd8192) $fatal(1,"negative endpoint");
        batch(1,1023);
        if(bend!==16'sd8191 || calibrated_bend!==16'sd8191) $fatal(1,"positive endpoint");

        // Average distinct values, then interleave channels. A stale filtered
        // register or a shared accumulator cannot pass these observations.
        sample(1,0,512);sample(1,1023,512);sample(1,0,512);sample(1,1023,512);
        if(fx!==512 || bend!==0 || value!==0 || pv!==1) $fatal(1,"four-sample average");
        repeat(3) sample(1,900,512);
        batch(2,512);
        if(bend!==0) $fatal(1,"partial X average was published by Y");
        sample(1,900,512);
        if(pv!==1 || bend<=0 || id!==`PARAM_PITCH_BEND) $fatal(1,"interleaved X average");
        sample(0,0,1023);
        if(pv!==0 || bend<=0) $fatal(1,"FSR channel changed joystick");
        failed_sample(0);
        if(pv!==0 || bend<=0) $fatal(1,"FSR error changed joystick");

        // Failed conversions cancel the axis and discard a partial average.
        repeat(3) sample(1,1023,512);
        failed_sample(1);
        if(pv!==1 || value!==0 || id!==`PARAM_PITCH_BEND || bend!==0 || fx!==512)
            $fatal(1,"SPI failure left bend active");
        failed_sample(1);
        if(pv!==0) $fatal(1,"repeated failure flooded queue");
        batch(1,512);
        if(bend!==0) $fatal(1,"failed partial average leaked into recovery");
        batch(2,0);
        if(mod!==65535 || calibrated_mod!==65535) $fatal(1,"negative Y endpoint");
        batch(2,1023);
        if(mod!==65535 || calibrated_mod!==65535) $fatal(1,"positive Y endpoint");
        failed_sample(2);
        if(pv!==1 || value!==0 || id!==`PARAM_MODULATION || mod!==0 || fy!==512)
            $fatal(1,"SPI failure left Y modulation active");
        batch(2,530);if(mod!==0 || calibrated_mod!==0) $fatal(1,"calibrated Y center");

        // Sweep the whole ADC range: monotonic pitch, limits and inclusive
        // deadzone must hold without overflow or a sign reversal.
        previous=-8192;
        for(i=0;i<1024;i=i+1) begin
            batch(1,i);
            if(bend<previous || bend < -8192 || bend > 8191) $fatal(1,"non-monotonic/overflow bend");
            if(i>=480 && i<=544 && bend!==0) $fatal(1,"deadzone noise changed pitch");
            previous=bend;
        end
        repeat(3) sample(1,0,512);
        @(negedge clk);rst_n=0;
        @(negedge clk);rst_n=1;
        batch(1,512);
        if(bend!==0 || mod!==0) $fatal(1,"reset retained partial average or modulation");
        $display("PASS joystick: complete/interleaved averages, calibrated endpoints, full ADC sweep, deadzone, SPI failure/recovery and reset");
        $finish;
    end
    initial begin #1000000;$fatal(1,"joystick timeout");end
endmodule

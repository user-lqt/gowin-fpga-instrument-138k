`timescale 1ns/1ps
module tb_keyboard_led_strip;
    reg clk=0,rst_n=0;
    always #40.69 clk=~clk;
    reg lesson_running=0;
    reg [23:0] guide_keys=0;
    wire din;
    wire [23:0] remaining;
    keyboard_led_strip dut(.clk(clk),.rst_n(rst_n),.lesson_running(lesson_running),
        .guide_keys(guide_keys),.led_din(din),.remaining(remaining));
    integer lamp,b,high_cycles,k;
    reg [23:0] received,expected;
    time previous_rise=0,last_fall=0;
    always @(posedge din) begin
        if(previous_rise!=0 && $time-previous_rise < 10000 &&
            ($time-previous_rise < 1200 || $time-previous_rise > 1240))
            $fatal(1,"bit period out of range");
        if(previous_rise!=0 && $time-previous_rise >= 10000 && $time-last_fall < 80000)
            $fatal(1,"reset low shorter than 80 us");
        previous_rise=$time;
    end
    always @(negedge din) last_fall=$time;
    task check_frame;
        input [23:0] mask;
        begin
            @(posedge dut.sending);
            #1;
            for(lamp=1;lamp<=49;lamp=lamp+1) begin
                received=0;
                for(b=23;b>=0;b=b-1) begin
                    @(posedge din);
                    high_cycles=0;
                    while(din) begin
                        @(negedge clk);
                        if(din) high_cycles=high_cycles+1;
                    end
                    if(high_cycles!=4 && high_cycles!=9) $fatal(1,"pulse width %0d",high_cycles);
                    received[b]=(high_cycles==9);
                end
                expected=0;
                for(k=0;k<24;k=k+1)
                    if(lamp==(k<12 ? 2*k+2 : 2*k+3) && mask[k]) expected=24'h200000;
                if(received!==expected) $fatal(1,"LED %0d: %h expected %h",lamp,received,expected);
            end
            @(negedge dut.sending);
        end
    endtask
    integer key;
    initial begin
        #200;rst_n=1;
        check_frame(24'd0);
        lesson_running=1;
        for(key=0;key<24;key=key+1) begin
            @(negedge clk); guide_keys=24'b1<<key;
            repeat(3) @(negedge clk);
            check_frame(24'b1<<key);
        end
        lesson_running=0;
        check_frame(0);
        lesson_running=1;guide_keys=1;
        check_frame(1);
        rst_n=0;#200;rst_n=1;
        check_frame(1);
        $display("PASS: 49 pixels, all 24 targets, mode exit black, re-entry, reset, 0/1 widths");
        $finish;
    end
    initial begin #50000000;$fatal(1,"timeout");end
endmodule

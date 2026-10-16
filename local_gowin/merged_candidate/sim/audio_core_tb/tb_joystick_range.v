`timescale 1ns/1ps
module tb_joystick_range;
    joystick_control #(.MAX_BEND(4096)) dut(
        .clk(1'b0),.rst_n(1'b0),.sample_valid(1'b0),.sample_error(1'b0),
        .sample_channel(3'd0),.ch1_x(10'd0),.ch2_y(10'd0));
    integer x,expected,actual;
    initial begin
        for(x=0;x<=1023;x=x+1) begin
            if(x<480) expected=-((480-x)*4096/480);
            else if(x>544) expected=(x-544)*4095/479;
            else expected=0;
            actual=$signed(dut.bend_from_raw(x));
            if(actual!=expected) $fatal(1,"MAX_BEND parameter x=%d got %d expected %d",x,actual,expected);
        end
        $display("PASS non-default MAX_BEND full ADC sweep");
        $finish;
    end
endmodule

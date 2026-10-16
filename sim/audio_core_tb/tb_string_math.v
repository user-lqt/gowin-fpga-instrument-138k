`timescale 1ns/1ps
module tb_string_math;
    reg clk=0;
    always #5 clk=~clk;
    reg [31:0] forced_phase=0;
    integer position,expected,old_displacement;
    plucked_string #(.SHARE_ARITHMETIC(0)) dut(.clk(clk),.rst_n(1'b0),.sample_tick(1'b0),
        .note_on(1'b0),.enabled(1'b0),.fc(32'd0),
        .period_q16(48'd7149370),.velocity(8'd120));
    initial begin
        force dut.fill_phase=forced_phase;
        for(position=0;position<65536;position=position+1) begin
            forced_phase=position<<16;#1;
            old_displacement=position<16384 ? position*2-16384 :
                ((65535-position)*2/3)-16384;
            expected=old_displacement>>>5;
            if($signed(dut.displacement_scaled)!==expected)
                $fatal(1,"narrow divider mismatch at %0d",position);
        end
        release dut.fill_phase;
        $display("STRING MATH PASS: all 65536 phases bit-exact after 17-to-12-bit divider reduction");
        $finish;
    end
endmodule

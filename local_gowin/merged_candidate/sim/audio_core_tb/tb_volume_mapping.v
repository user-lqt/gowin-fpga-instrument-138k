`timescale 1ns/1ps
module tb_volume_mapping;
 reg clk=0,rst_n=0,up=0,down=0;
 wire [15:0] value,payload;
 wire valid;
 always #5 clk=~clk;
 parameter_manager dut(.clk(clk),.rst_n(rst_n),.step_up(up),.step_down(down),
   .volume_value(value),.param_value(payload),.param_valid(valid),.select_press(1'b0));
 integer i,expected;
 task check;
 begin
   expected=(value*65535+63)/127;
   if(payload!==expected[15:0]) $fatal(1,"volume %d mapped to %d expected %d",value,payload,expected);
 end endtask
 initial begin
   repeat(3) @(negedge clk);rst_n=1;@(negedge clk);
   if(!valid || value!=64) $fatal(1,"startup mapping absent");check;
   down=1;repeat(64) begin @(negedge clk);check;end
   down=0;up=1;
   for(i=1;i<=127;i=i+1) begin @(negedge clk);check;if(value!=i) $fatal(1,"step mismatch");end
   rst_n=0;@(negedge clk);rst_n=1;up=0;@(negedge clk);check;
   $display("PASS volume mapping all 128 values and reset");$finish;
 end
endmodule

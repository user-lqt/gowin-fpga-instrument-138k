// r22sdf adapter: exact stage-strided synchronous coefficient ROM.
module Twiddle #(parameter TW_FF=1,ADDR_SHIFT=0)(
 input wire clock,input wire [13:0] addr,
 output wire [15:0] tw_re,tw_im);
 wire [31:0] value;
 spectral_twiddle_rom #(.ADDR_SHIFT(ADDR_SHIFT)) u_rom(.clk(clock),.address(addr[10:0]),.value(value));
 assign tw_re=value[31:16];assign tw_im=value[15:0];
endmodule

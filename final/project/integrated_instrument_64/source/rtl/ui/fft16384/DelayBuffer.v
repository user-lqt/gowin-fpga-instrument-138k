// r22sdf-compatible delay. Large delays use synchronous RAM, not flip-flop chains.
// Memory reads the next ring slot, preserving exactly DEPTH clocks of delay.
module DelayBuffer #(parameter DEPTH=32,WIDTH=16)(
 input wire clock,input wire [WIDTH-1:0] di_re,di_im,
 output wire [WIDTH-1:0] do_re,do_im);
 generate if(DEPTH>=32) begin:ram_delay
 localparam AW=$clog2(DEPTH);
 reg [AW-1:0] write_address=0;
 wire [AW-1:0] next_address=write_address+1'b1;
 (* syn_ramstyle="block_ram" *) reg [2*WIDTH-1:0] memory[0:DEPTH-1];
 reg [2*WIDTH-1:0] output_data;
 always @(posedge clock) begin
 memory[write_address]<={di_re,di_im};
 output_data<=memory[next_address];
 write_address<=next_address;
 end
 assign {do_re,do_im}=output_data;
 end else begin:short_delay
 reg [2*WIDTH-1:0] data[0:DEPTH-1];integer i;
 always @(posedge clock) begin
 data[0]<={di_re,di_im};
 for(i=1;i<DEPTH;i=i+1) data[i]<=data[i-1];
 end
 assign {do_re,do_im}=data[DEPTH-1];
 end endgenerate
endmodule

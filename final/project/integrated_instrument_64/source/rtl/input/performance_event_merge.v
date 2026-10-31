`include "event_defs.vh"
// Two-source FIFO. Pop first, then append A and B; simultaneous events survive.
module performance_event_merge(input wire clk,rst_n,
 input wire a_valid,input wire [1:0] a_type,input wire [6:0] a_note,input wire [7:0] a_velocity,
 input wire b_valid,input wire [1:0] b_type,input wire [6:0] b_note,input wire [7:0] b_velocity,
 output reg valid,output reg [1:0] kind,output reg [6:0] note,output reg [7:0] velocity,
 output reg overflow);
 // Consecutive writes always have opposite parity. Each bank therefore
 // needs only one write port, including cycles that accept both sources.
 reg [16:0] even_fifo[0:7],odd_fifo[0:7];
 reg [3:0] rd,wr;reg [4:0] count;
 wire pop=count!=0;
 wire [4:0] remaining=count-{4'd0,pop};
 wire push_a=a_valid && remaining<16;
 wire push_b=b_valid && remaining+{4'd0,push_a}<16;
 wire [3:0] b_address=wr+{3'd0,push_a};
 wire a_even=push_a && !wr[0];
 wire b_even=push_b && !b_address[0];
 wire a_odd=push_a && wr[0];
 wire b_odd=push_b && b_address[0];
 always @(posedge clk) begin
 if(rst_n) begin
 if(a_even || b_even)
 even_fifo[a_even ? wr[3:1] : b_address[3:1]]<=
     a_even ? {a_type,a_note,a_velocity} : {b_type,b_note,b_velocity};
 if(a_odd || b_odd)
 odd_fifo[a_odd ? wr[3:1] : b_address[3:1]]<=
     a_odd ? {a_type,a_note,a_velocity} : {b_type,b_note,b_velocity};
 end
 end
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin rd<=0;wr<=0;count<=0;valid<=0;kind<=0;note<=0;velocity<=0;overflow<=0;end
 else begin
 valid<=pop;
 if(pop) begin
 {kind,note,velocity}<=rd[0] ? odd_fifo[rd[3:1]] : even_fifo[rd[3:1]];
 rd<=rd+1'b1;
 end
 if((a_valid && !push_a) || (b_valid && !push_b)) overflow<=1;
 wr<=wr+{3'd0,push_a}+{3'd0,push_b};
 count<=remaining+{4'd0,push_a}+{4'd0,push_b};
 end end
endmodule

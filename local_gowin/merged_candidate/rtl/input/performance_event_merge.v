`include "event_defs.vh"
// Two-source FIFO. Pop first, then append A and B; simultaneous events survive.
module performance_event_merge(input wire clk,rst_n,
 input wire a_valid,input wire [1:0] a_type,input wire [6:0] a_note,input wire [7:0] a_velocity,
 input wire b_valid,input wire [1:0] b_type,input wire [6:0] b_note,input wire [7:0] b_velocity,
 output reg valid,output reg [1:0] kind,output reg [6:0] note,output reg [7:0] velocity,
 output reg overflow);
 reg [16:0] fifo[0:15];reg [3:0] rd,wr;reg [4:0] count;
 integer n;reg [3:0] w;
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin rd<=0;wr<=0;count<=0;valid<=0;kind<=0;note<=0;velocity<=0;overflow<=0;end
 else begin
 valid<=0;n=count;w=wr;
 if(count!=0) begin {kind,note,velocity}<=fifo[rd];rd<=rd+1'b1;n=n-1;valid<=1;end
 if(a_valid) begin if(n<16) begin fifo[w]<={a_type,a_note,a_velocity};w=w+1'b1;n=n+1;end else overflow<=1;end
 if(b_valid) begin if(n<16) begin fifo[w]<={b_type,b_note,b_velocity};w=w+1'b1;n=n+1;end else overflow<=1;end
 wr<=w;count<=n[4:0];
 end end
endmodule

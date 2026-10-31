// Four producers can emit on the same clock. Preserve A, B, C, D ordering.
// Emit one item per audio sample; overflow is sticky and exposed at the top.
module encoder_param_queue (
    input wire clk,rst_n,sample_tick,
    input wire a_valid,b_valid,c_valid,d_valid,
    input wire [3:0] a_id,b_id,c_id,d_id,
    input wire [15:0] a_value,b_value,c_value,d_value,
    output wire valid,
    output wire [3:0] id,
    output wire [15:0] value,
    output reg overflow
);
    reg [19:0] queue[0:7];
    reg [2:0] rd,wr;
    reg [3:0] count;
    wire pop=sample_tick && count!=0;
    wire [4:0] free_slots=5'd8-{1'b0,count}+pop;
    wire push_a=a_valid && free_slots!=0;
    wire push_b=b_valid && free_slots>{4'd0,push_a};
    wire push_c=c_valid && free_slots>{4'd0,push_a}+{4'd0,push_b};
    wire push_d=d_valid && free_slots>{4'd0,push_a}+{4'd0,push_b}+{4'd0,push_c};
    assign valid=pop;
    assign id=queue[rd][19:16];
    assign value=queue[rd][15:0];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin rd<=0;wr<=0;count<=0;overflow<=0;end
        else begin
            if(pop) rd<=rd+1'b1;
            if(push_a) queue[wr]<={a_id,a_value};
            if(push_b) queue[(wr+{2'd0,push_a}) & 3'd7]<={b_id,b_value};
            if(push_c) queue[(wr+{2'd0,push_a}+{2'd0,push_b}) & 3'd7]<={c_id,c_value};
            if(push_d) queue[(wr+{2'd0,push_a}+{2'd0,push_b}+{2'd0,push_c}) & 3'd7]<={d_id,d_value};
            wr<=wr+{2'd0,push_a}+{2'd0,push_b}+{2'd0,push_c}+{2'd0,push_d};
            count<=count+{3'd0,push_a}+{3'd0,push_b}+{3'd0,push_c}+{3'd0,push_d}-{3'd0,pop};
            if((a_valid && !push_a)||(b_valid && !push_b)||(c_valid && !push_c)||(d_valid && !push_d)) overflow<=1;
        end
    end
endmodule

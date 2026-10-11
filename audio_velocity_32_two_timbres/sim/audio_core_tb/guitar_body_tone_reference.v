// Isolated candidate: tone outputs settle before clock 70; filter state
// settles before the next 256-clock tick. Coefficients/rounding are unchanged.
module guitar_body_tone_reference #(parameter integer LANES=16) (
    input wire clk,rst_n,sample_tick,
    input wire [LANES-1:0] note_on,
    input wire [LANES*16-1:0] string_waves,
    output wire [LANES*16-1:0] waves
);
    localparam integer INDEX_BITS=LANES>1 ? $clog2(LANES) : 1;
    reg [INDEX_BITS-1:0] lane,tone_lane;
    reg [3:0] step;
    reg tone_busy;
    reg [LANES-1:0] cancelled;
    reg signed [23:0] x1[0:LANES-1],x2[0:LANES-1];
    reg signed [23:0] low1[0:LANES-1],low2[0:LANES-1];
    reg signed [23:0] mid1[0:LANES-1],mid2[0:LANES-1];
    reg signed [23:0] high1[0:LANES-1],high2[0:LANES-1],tone[0:LANES-1];
    reg signed [24:0] difference[0:LANES-1];
    reg signed [15:0] captured[0:LANES-1];
    reg signed [24:0] operand;
    reg signed [21:0] coefficient;
    reg signed [43:0] high_product;
    wire signed [43:0] wide_operand={{19{operand[24]}},operand};
    wire signed [42:0] low_product=operand*$signed({1'b0,coefficient[16:0]});
    wire signed [43:0] product={{1{low_product[42]}},low_product}+(high_product <<< 17);
    reg signed [43:0] sum;
    wire signed [43:0] completed_sum=sum+product;
    wire signed [25:0] coloured=($signed(captured[tone_lane]) >>> 1)+
        low1[tone_lane]+mid1[tone_lane]+(high1[tone_lane] >>> 1);
    wire signed [26:0] tone_delta=coloured-tone[tone_lane];
    wire signed [26:0] next_tone=tone[tone_lane]+
        (tone_delta >>> 1)+(tone_delta >>> 2);
    wire signed [24:0] next_difference=
        $signed({captured[tone_lane][15],captured[tone_lane]})-x2[tone_lane];
    always @* begin
        operand=difference[lane];coefficient=8171;
        case(step)
            2: begin operand=low1[lane];coefficient=2080233;end
            3: begin operand=low2[lane];coefficient=-1032235;end
            4: coefficient=21814;
            5: begin operand=mid1[lane];coefficient=2046095;end
            6: begin operand=mid2[lane];coefficient=-1004948;end
            7: coefficient=33084;
            8: begin operand=high1[lane];coefficient=2003857;end
            9: begin operand=high2[lane];coefficient=-982408;end
        endcase
        case(coefficient[21:17])
            5'd15: high_product=(wide_operand <<< 4)-wide_operand;
            5'b11000: high_product=-(wide_operand <<< 3);
            default: high_product=0;
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            lane<=0;tone_lane<=0;step<=0;tone_busy<=0;cancelled<=0;sum<=0;
        end else if(sample_tick) begin
            lane<=0;tone_lane<=0;step<=0;tone_busy<=1;cancelled<=note_on;sum<=0;
        end else begin
            cancelled<=cancelled|note_on;
            if(tone_busy) begin
                if(tone_lane==LANES-1) begin tone_busy<=0;step<=1;end
                else tone_lane<=tone_lane+1'b1;
            end else if(step!=0) begin
                if(step==9) begin
                    if(lane==LANES-1) step<=0;
                    else begin lane<=lane+1'b1;step<=1;end
                end else step<=step+1'b1;
                case(step)
                    1,4,7: sum<=product;
                    2,5,8: sum<=completed_sum;
                    default: ;
                endcase
            end
        end
    end
    genvar v;
    generate for(v=0;v<LANES;v=v+1) begin : states
        assign waves[v*16+:16]=tone[v]>32767 ? 16'h7fff :
            tone[v]< -32768 ? 16'h8000 : tone[v][15:0];
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                x1[v]<=0;x2[v]<=0;low1[v]<=0;low2[v]<=0;mid1[v]<=0;mid2[v]<=0;
                high1[v]<=0;high2[v]<=0;tone[v]<=0;difference[v]<=0;captured[v]<=0;
            end else begin
                if(sample_tick) captured[v]<=string_waves[v*16+:16];
                if(note_on[v]) begin
                    x1[v]<=0;x2[v]<=0;low1[v]<=0;low2[v]<=0;mid1[v]<=0;mid2[v]<=0;
                    high1[v]<=0;high2[v]<=0;tone[v]<=0;
                end else if(!sample_tick && !cancelled[v]) begin
                    if(tone_busy && tone_lane==v) begin
                        x1[v]<=captured[v];x2[v]<=x1[v];difference[v]<=next_difference;
                        tone[v]<=next_tone[23:0];
                    end else if(!tone_busy && lane==v) begin
                        case(step)
                            3: begin low2[v]<=low1[v];low1[v]<=completed_sum >>> 20;end
                            6: begin mid2[v]<=mid1[v];mid1[v]<=completed_sum >>> 20;end
                            9: begin high2[v]<=high1[v];high1[v]<=completed_sum >>> 20;end
                            default: ;
                        endcase
                    end
                end
            end
        end
    end endgenerate
endmodule

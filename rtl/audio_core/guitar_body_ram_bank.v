// Resource-oriented guitar body bank.
// The recurrence state is stored in one small synchronous RAM per lane bank
// so the filter does not replicate 192 state bits and its fanout per voice.
module guitar_body_ram_bank #(parameter integer LANES=16)(
    input wire clk,rst_n,sample_tick,
    input wire [LANES-1:0] note_on,
    input wire [LANES*16-1:0] string_waves,
    output wire [LANES*16-1:0] waves
);
    localparam integer IB=LANES>1 ? $clog2(LANES) : 1;
    reg [191:0] state_ram[0:LANES-1];
    reg [191:0] read_state;
    reg [LANES-1:0] initialized,cancelled;
    reg [LANES*16-1:0] captured;
    reg signed [23:0] tone[0:LANES-1];
    reg [IB-1:0] lane;
    reg [3:0] step;
    reg tone_phase;
    reg signed [23:0] x1,x2,low1,low2,mid1,mid2,high1,high2;
    reg signed [24:0] difference,operand;
    reg signed [21:0] coefficient;
    reg signed [43:0] high_product,sum;
    wire signed [43:0] wide_operand={{19{operand[24]}},operand};
    wire signed [42:0] low_product=operand*$signed({1'b0,coefficient[16:0]});
    wire signed [43:0] product={{1{low_product[42]}},low_product}+(high_product <<< 17);
    wire signed [43:0] completed_sum=sum+product;
    wire signed [15:0] sample=captured[lane*16+:16];
    wire signed [25:0] coloured=($signed(sample) >>> 1)+low1+mid1+(high1 >>> 1);
    wire signed [26:0] tone_delta=coloured-tone[lane];
    wire signed [26:0] next_tone=tone[lane]+(tone_delta >>> 1)+(tone_delta >>> 2);
    wire signed [24:0] next_difference=$signed({sample[15],sample})-x2;
    wire signed [23:0] completed_high=completed_sum >>> 20;
    wire write_state=rst_n && !tone_phase && step==12 && !sample_tick &&
        !cancelled[lane] && !note_on[lane];

    always @(posedge clk) begin
        read_state<=state_ram[lane];
        if(write_state)
            state_ram[lane]<={x1,x2,low1,low2,mid1,mid2,completed_high,high1};
    end

    always @* begin
        operand=difference;
        coefficient=8171;
        case(step)
            5: begin operand=low1;coefficient=2080233;end
            6: begin operand=low2;coefficient=-1032235;end
            7: coefficient=21814;
            8: begin operand=mid1;coefficient=2046095;end
            9: begin operand=mid2;coefficient=-1004948;end
            10: coefficient=33084;
            11: begin operand=high1;coefficient=2003857;end
            12: begin operand=high2;coefficient=-982408;end
            default: ;
        endcase
        case(coefficient[21:17])
            5'd15: high_product=(wide_operand <<< 4)-wide_operand;
            5'b11000: high_product=-(wide_operand <<< 3);
            default: high_product=0;
        endcase
    end

    integer v;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            initialized<=0;
            cancelled<=0;
            captured<=0;
            lane<=0;
            step<=0;
            tone_phase<=0;
            sum<=0;
            x1<=0;x2<=0;low1<=0;low2<=0;mid1<=0;mid2<=0;high1<=0;high2<=0;
            difference<=0;
            for(v=0;v<LANES;v=v+1)
                tone[v]<=0;
        end else begin
            cancelled<=cancelled|note_on;
            for(v=0;v<LANES;v=v+1)
                if(note_on[v]) begin
                    initialized[v]<=0;
                    tone[v]<=0;
                end
            if(sample_tick) begin
                lane<=0;
                step<=1;
                tone_phase<=1;
                captured<=string_waves;
                cancelled<=note_on;
                sum<=0;
            end else if(step!=0) begin
                if(tone_phase && step==3) begin
                    step<=1;
                    if(lane==LANES-1) begin lane<=0;tone_phase<=0;end
                    else lane<=lane+1'b1;
                end else if(!tone_phase && step==12) begin
                    step<=lane==LANES-1 ? 0 : 1;
                    if(lane!=LANES-1) lane<=lane+1'b1;
                end else step<=step+1'b1;
                case(step)
                    2: {x1,x2,low1,low2,mid1,mid2,high1,high2}<=
                        initialized[lane] ? read_state : 192'd0;
                    3: begin
                        difference<=next_difference;
                        x2<=x1;
                        x1<=sample;
                    end
                    4,7,10: sum<=product;
                    5,8,11: sum<=completed_sum;
                    6: begin low2<=low1;low1<=completed_sum >>> 20;end
                    9: begin mid2<=mid1;mid1<=completed_sum >>> 20;end
                    12: begin high2<=high1;high1<=completed_sum >>> 20;end
                    default: ;
                endcase
                if(write_state)
                    initialized[lane]<=1;
                if(tone_phase && step==3 && !cancelled[lane] && !note_on[lane])
                    tone[lane]<=next_tone[23:0];
            end
        end
    end

    genvar g;
    generate
        for(g=0;g<LANES;g=g+1) begin : outputs
            assign waves[g*16+:16]=tone[g]>32767 ? 16'h7fff :
                tone[g]< -32768 ? 16'h8000 : tone[g][15:0];
        end
    endgenerate
endmodule

// Broad body-colour filters, not a measured acoustic guitar impulse response.
module guitar_body (
    input wire clk, rst_n, sample_tick, note_on,
    input wire signed [15:0] string_wave,
    output wire signed [15:0] wave
);
    reg signed [23:0] x1, x2;
    reg signed [23:0] low1, low2, mid1, mid2, high1, high2, tone;
    wire signed [24:0] difference = $signed({string_wave[15], string_wave}) - x2;
    // Q20, 48 kHz: broad 180/650/1250-Hz bands. Upper bands retain
    // the attack's string texture rather than colouring only the fundamental.
    reg [3:0] cycle;
    reg signed [24:0] saved_difference;
    reg signed [24:0] operand;
    reg signed [21:0] coefficient;
    // Only bits 43:20 reach the original 24-bit filter state.
    wire signed [42:0] low_product = operand * $signed({1'b0,coefficient[16:0]});
    wire signed [43:0] wide_operand = {{19{operand[24]}},operand};
    reg signed [43:0] high_product;
    always @* begin
        case (coefficient[21:17])
            5'd15: high_product = (wide_operand <<< 4) - wide_operand;
            5'b11000: high_product = -(wide_operand <<< 3);
            default: high_product = 0;
        endcase
    end
    // Signed coefficient = unsigned low 17 bits + signed high bits * 2^17.
    wire signed [43:0] product =
        {{1{low_product[42]}},low_product} + (high_product <<< 17);
    reg signed [43:0] sum;
    wire signed [43:0] completed_sum = sum + product;
    always @* begin
        operand=saved_difference; coefficient=8171;
        case(cycle)
            2: begin operand=low1; coefficient=2080233; end
            3: begin operand=low2; coefficient=-1032235; end
            4: begin operand=saved_difference; coefficient=21814; end
            5: begin operand=mid1; coefficient=2046095; end
            6: begin operand=mid2; coefficient=-1004948; end
            7: begin operand=saved_difference; coefficient=33084; end
            8: begin operand=high1; coefficient=2003857; end
            9: begin operand=high2; coefficient=-982408; end
        endcase
    end
    wire signed [25:0] coloured =
        ($signed(string_wave) >>> 1) + low1 + mid1 + (high1 >>> 1);
    wire signed [26:0] tone_delta = coloured - tone;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x1 <= 0; x2 <= 0; low1 <= 0; low2 <= 0;
            mid1 <= 0; mid2 <= 0; high1 <= 0; high2 <= 0; tone <= 0;
            cycle<=0; sum<=0; saved_difference<=0;
        end else if (note_on) begin
            x1 <= 0; x2 <= 0; low1 <= 0; low2 <= 0;
            mid1 <= 0; mid2 <= 0; high1 <= 0; high2 <= 0; tone <= 0;
            cycle<=0; sum<=0;
        end else if (sample_tick) begin
            x1 <= string_wave; x2 <= x1;
            saved_difference<=difference;
            tone <= tone + (tone_delta >>> 1) + (tone_delta >>> 2);
            cycle<=1;
        end else if(cycle!=0) begin
            cycle<=cycle==9 ? 0 : cycle+1'b1;
            case(cycle)
                1,4,7: sum<=product;
                2,5,8: sum<=completed_sum;
                3: begin low2<=low1; low1<=completed_sum >>> 20; end
                6: begin mid2<=mid1; mid1<=completed_sum >>> 20; end
                9: begin high2<=high1; high1<=completed_sum >>> 20; end
            endcase
        end
    end
    assign wave = tone > 32767 ? 16'sh7fff :
                  tone < -32768 ? 16'sh8000 : tone[15:0];
endmodule

// State remains per voice; a bank processes nine products per lane per sample.
module guitar_body_bank #(
    parameter integer LANES=8
) (
    input wire clk, rst_n, sample_tick,
    input wire [LANES-1:0] note_on,
    input wire [LANES*16-1:0] string_waves,
    output wire [LANES*16-1:0] waves
);
    localparam integer LANE_BITS=LANES>1 ? $clog2(LANES) : 1;
    reg [LANE_BITS-1:0] lane;
    reg [3:0] step;
    reg [LANES-1:0] cancelled;
    wire [LANES*25-1:0] differences;
    wire [LANES*24-1:0] lows1,lows2,mids1,mids2,highs1,highs2;
    reg signed [24:0] operand;
    reg signed [21:0] coefficient;
    reg signed [43:0] high_product;
    wire signed [43:0] wide_operand={{19{operand[24]}},operand};
    wire signed [42:0] low_product=operand*$signed({1'b0,coefficient[16:0]});
    wire signed [43:0] product={{1{low_product[42]}},low_product}+
        (high_product <<< 17);
    reg signed [43:0] sum;
    wire signed [43:0] completed_sum=sum+product;
    always @* begin
        operand=$signed(differences[lane*25+:25]); coefficient=8171;
        case(step)
            2: begin operand=$signed(lows1[lane*24+:24]); coefficient=2080233; end
            3: begin operand=$signed(lows2[lane*24+:24]); coefficient=-1032235; end
            4: coefficient=21814;
            5: begin operand=$signed(mids1[lane*24+:24]); coefficient=2046095; end
            6: begin operand=$signed(mids2[lane*24+:24]); coefficient=-1004948; end
            7: coefficient=33084;
            8: begin operand=$signed(highs1[lane*24+:24]); coefficient=2003857; end
            9: begin operand=$signed(highs2[lane*24+:24]); coefficient=-982408; end
        endcase
        case(coefficient[21:17])
            5'd15: high_product=(wide_operand <<< 4)-wide_operand;
            5'b11000: high_product=-(wide_operand <<< 3);
            default: high_product=0;
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin lane<=0; step<=0; cancelled<=0; sum<=0; end
        else begin
            if(sample_tick) begin
                lane<=0; step<=1; sum<=0; cancelled<=note_on;
            end else begin
                cancelled<=cancelled|note_on;
                if(step!=0) begin
                    if(step==9) begin
                        if(lane==LANES-1) step<=0;
                        else begin lane<=lane+1'b1; step<=1; end
                    end else step<=step+1'b1;
                    case(step)
                        1,4,7: sum<=product;
                        2,5,8: sum<=completed_sum;
                        default: ;
                    endcase
                end
            end
        end
    end
    genvar v;
    generate for(v=0;v<LANES;v=v+1) begin : states
        reg signed [23:0] x1,x2,low1,low2,mid1,mid2,high1,high2,tone;
        reg signed [24:0] saved_difference;
        wire signed [15:0] string_wave=string_waves[v*16+:16];
        wire signed [24:0] difference=$signed({string_wave[15],string_wave})-x2;
        wire signed [25:0] coloured=($signed(string_wave) >>> 1)+low1+mid1+(high1 >>> 1);
        wire signed [26:0] tone_delta=coloured-tone;
        assign differences[v*25+:25]=saved_difference;
        assign lows1[v*24+:24]=low1;
        assign lows2[v*24+:24]=low2;
        assign mids1[v*24+:24]=mid1;
        assign mids2[v*24+:24]=mid2;
        assign highs1[v*24+:24]=high1;
        assign highs2[v*24+:24]=high2;
        assign waves[v*16+:16]=tone>32767 ? 16'h7fff :
            tone < -32768 ? 16'h8000 : tone[15:0];
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                x1<=0; x2<=0; low1<=0; low2<=0; mid1<=0; mid2<=0;
                high1<=0; high2<=0; tone<=0; saved_difference<=0;
            end else if(note_on[v]) begin
                x1<=0; x2<=0; low1<=0; low2<=0; mid1<=0; mid2<=0;
                high1<=0; high2<=0; tone<=0;
            end else if(sample_tick) begin
                x1<=string_wave; x2<=x1; saved_difference<=difference;
                tone<=tone+(tone_delta >>> 1)+(tone_delta >>> 2);
            end else if(lane==v && !cancelled[v]) begin
                case(step)
                    3: begin low2<=low1; low1<=completed_sum >>> 20; end
                    6: begin mid2<=mid1; mid1<=completed_sum >>> 20; end
                    9: begin high2<=high1; high1<=completed_sum >>> 20; end
                    default: ;
                endcase
            end
        end
    end endgenerate
endmodule

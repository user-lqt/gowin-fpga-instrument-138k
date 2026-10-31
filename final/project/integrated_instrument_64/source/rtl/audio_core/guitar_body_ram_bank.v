// Resource-oriented guitar body bank.
// The recurrence state is stored in one small synchronous RAM per lane bank
// so the filter does not replicate 192 state bits and its fanout per voice.
module guitar_body_ram_bank #(parameter integer LANES=16,
    parameter integer COMPACT_STATE=0,
    parameter integer PARALLEL_OUTPUT=1)(
    input wire clk,rst_n,sample_tick,
    input wire [LANES-1:0] note_on,
    input wire [LANES*16-1:0] string_waves,
    output wire [LANES*16-1:0] waves,
    input wire [(LANES>1 ? $clog2(LANES) : 1)-1:0] output_lane,
    output wire signed [15:0] selected_wave
);
    localparam integer IB=LANES>1 ? $clog2(LANES) : 1;
    (* syn_ramstyle="distributed_ram" *) reg [191:0] state_ram[0:LANES-1];
    reg [191:0] read_state;
    reg [LANES-1:0] initialized,cancelled;
    reg [LANES*16-1:0] captured;
    (* syn_ramstyle="distributed_ram" *) reg signed [23:0] tone_ram[0:LANES-1];
    reg signed [23:0] read_tone;
    reg [LANES-1:0] tone_valid;
    reg [IB-1:0] lane;
    reg [3:0] step;
    reg tone_phase;
    reg signed [23:0] x1,x2,low1,low2,mid1,mid2,high1,high2;
    reg signed [24:0] difference,operand;
    reg signed [21:0] coefficient;
    reg signed [43:0] sum;
    wire signed [46:0] full_product=operand*coefficient;
    wire signed [43:0] product=full_product[43:0];
    wire signed [43:0] completed_sum=sum+product;
    wire signed [15:0] sample=captured[lane*16+:16];
    wire signed [25:0] coloured=($signed(sample) >>> 1)+low1+mid1+(high1 >>> 1);
    wire signed [23:0] selected_tone=tone_valid[lane] ? read_tone : 24'sd0;
    wire signed [26:0] tone_delta=coloured-selected_tone;
    wire signed [26:0] next_tone=selected_tone+(tone_delta >>> 1)+(tone_delta >>> 2);
    wire signed [23:0] stored_tone=next_tone[23:0];
    wire signed [15:0] next_wave=stored_tone>32767 ? 16'h7fff :
        stored_tone< -32768 ? 16'h8000 : stored_tone[15:0];
    wire signed [24:0] next_difference=$signed({sample[15],sample})-x2;
    wire signed [23:0] completed_high=completed_sum >>> 20;
    wire write_state=rst_n && !tone_phase && step==12 && !sample_tick &&
        !cancelled[lane] && !note_on[lane];
    wire write_tone=rst_n && tone_phase && step==3 && !sample_tick &&
        !cancelled[lane] && !note_on[lane];

    always @(posedge clk) begin
        read_state<=state_ram[lane];
        read_tone<=tone_ram[lane];
        if(write_tone) tone_ram[lane]<=stored_tone;
        if(write_state)
            state_ram[lane]<={x1,x2,low1,low2,mid1,mid2,completed_high,high1};
    end
    generate if(COMPACT_STATE) begin : compact_output
        wire signed [15:0] local_wave;
        if(PARALLEL_OUTPUT) begin : parallel_readers
            reg signed [15:0] memory[0:LANES-1];
            always @(posedge clk)
                if(write_tone) memory[lane]<=next_wave;
            assign local_wave=memory[output_lane];
            genvar compact_index;
            for(compact_index=0;compact_index<LANES;compact_index=compact_index+1) begin : outputs
                assign waves[compact_index*16+:16]=tone_valid[compact_index] ?
                    memory[compact_index] : 16'd0;
            end
        end else begin : local_reader
            guitar_body_output_ram #(.LANES(LANES)) storage(
                .clk(clk),.write_enable(write_tone),.write_lane(lane),
                .write_wave(next_wave),.read_lane(output_lane),.read_wave(local_wave));
            assign waves=0;
        end
        assign selected_wave=tone_valid[output_lane] ? local_wave : 16'd0;
    end else begin : parallel_output
        reg signed [15:0] memory[0:LANES-1];
        integer output_index;
        always @(posedge clk or negedge rst_n)
            if(!rst_n) begin
                for(output_index=0;output_index<LANES;output_index=output_index+1)
                    memory[output_index]<=0;
            end else begin
                for(output_index=0;output_index<LANES;output_index=output_index+1)
                    if(note_on[output_index]) memory[output_index]<=0;
                if(write_tone) memory[lane]<=next_wave;
            end
        assign selected_wave=tone_valid[output_lane] ? memory[output_lane] : 16'd0;
        genvar parallel_index;
        for(parallel_index=0;parallel_index<LANES;parallel_index=parallel_index+1) begin : outputs
            assign waves[parallel_index*16+:16]=PARALLEL_OUTPUT ?
                memory[parallel_index] : 16'd0;
        end
    end endgenerate

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
    end

    integer v;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            initialized<=0;
            tone_valid<=0;
            cancelled<=0;
            captured<=0;
            lane<=0;
            step<=0;
            tone_phase<=0;
            sum<=0;
            x1<=0;x2<=0;low1<=0;low2<=0;mid1<=0;mid2<=0;high1<=0;high2<=0;
            difference<=0;
        end else begin
            cancelled<=cancelled|note_on;
            for(v=0;v<LANES;v=v+1)
                if(note_on[v]) begin
                    initialized[v]<=0;
                    tone_valid[v]<=0;
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
                if(write_tone) begin
                    tone_valid[lane]<=1;
                end
            end
        end
    end

endmodule

module guitar_body_output_ram #(parameter integer LANES=16)(
    input wire clk,write_enable,
    input wire [(LANES>1 ? $clog2(LANES) : 1)-1:0] write_lane,read_lane,
    input wire signed [15:0] write_wave,
    output wire signed [15:0] read_wave
);
    reg [15:0] memory[0:LANES-1] /* synthesis syn_ramstyle="distributed_ram" */;
    always @(posedge clk)
        if(write_enable) memory[write_lane]<=write_wave;
    assign read_wave=memory[read_lane];
endmodule

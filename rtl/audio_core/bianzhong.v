// Eight approved inharmonic modes, with shared state arithmetic and ROM.
module bianzhong #(
    parameter integer DYNAMIC_PITCH=0
) (
    input wire clk,rst_n,sample_tick,note_on,
    input wire [31:0] fc,
    output reg signed [15:0] wave
);
    reg [31:0] phases [0:7];
    reg [23:0] levels [0:7];
    reg [31:0] increments [0:7];
    reg [7:0] audible;
    reg loading;
    reg load_half;
    reg [31:0] low_frequency_product;
    reg [2:0] load_mode;
    reg [31:0] saved_fc;
    reg [16:0] ratio;
    always @* begin
        case(load_mode)
            0: ratio=4096;
            1: ratio=6103;
            2: ratio=8356;
            3: ratio=10977;
            4: ratio=15442;
            5: ratio=20972;
            6: ratio=27976;
            7: ratio=33628;
        endcase
    end
    reg [3:0] cycle;
    wire [2:0] mode_index=cycle-4'd3;
    wire [23:0] selected_level=levels[mode_index];
    reg [13:0] loss;
    always @* begin
        case(mode_index)
            0,2: loss={7'd0,selected_level[23:17]}+(|selected_level[16:0]);
            1: loss={6'd0,selected_level[23:16]}+(|selected_level[15:0]);
            3: loss={5'd0,selected_level[23:15]}+(|selected_level[14:0]);
            4: loss={4'd0,selected_level[23:14]}+(|selected_level[13:0]);
            5: loss={3'd0,selected_level[23:13]}+(|selected_level[12:0]);
            6: loss={2'd0,selected_level[23:12]}+(|selected_level[11:0]);
            7: loss={1'd0,selected_level[23:11]}+(|selected_level[10:0]);
        endcase
    end
    wire [23:0] next_level=selected_level>loss ? selected_level-loss : 24'd0;
    reg [15:0] live_ratio;
    always @* begin
        case(mode_index)
            0: live_ratio=4096;
            1: live_ratio=6103;
            2: live_ratio=8356;
            3: live_ratio=10977;
            4: live_ratio=15442;
            5: live_ratio=20972;
            6: live_ratio=27976;
            7: live_ratio=33628;
        endcase
    end
    wire [47:0] live_product=fc*live_ratio;
    wire [31:0] next_phase=phases[mode_index]+
        (DYNAMIC_PITCH ? live_product[43:12] : increments[mode_index]);
    wire signed [15:0] sine;
    wavetable table_rom (.clk(clk),.addr(next_phase[31:20]),.dout(sine));
    reg [15:0] read_level;
    reg [6:0] read_weight;
    reg read_audible;
    // Two 16-bit chunks compute each exact frequency product (clocks 2..17).
    // That first frame is silent: all original mode phases have just reset.
    wire signed [17:0] operand_a=loading ?
        $signed({2'b0,load_half ? saved_fc[31:16] : saved_fc[15:0]}) :
        $signed(sine);
    wire signed [17:0] operand_b=loading ? $signed({2'b0,ratio[15:0]}) :
        $signed({2'b0,read_level});
    wire signed [35:0] product=operand_a*operand_b;
    wire [47:0] frequency_product={product[31:0],16'b0} +
        {16'b0,low_frequency_product};
    wire signed [32:0] enveloped=product[32:0];
    wire signed [41:0] envelope_wide={{9{enveloped[32]}},enveloped};
    reg signed [41:0] weight_a,weight_b;
    always @* begin
        weight_a=0; weight_b=0;
        // Exact approved integer weights; avoid a second wide DSP multiplier.
        case(read_weight)
            72: begin weight_a=envelope_wide <<< 6; weight_b=envelope_wide <<< 3; end
            28: begin weight_a=envelope_wide <<< 5; weight_b=-(envelope_wide <<< 2); end
            40: begin weight_a=envelope_wide <<< 5; weight_b=envelope_wide <<< 3; end
            24: begin weight_a=envelope_wide <<< 4; weight_b=envelope_wide <<< 3; end
            20: begin weight_a=envelope_wide <<< 4; weight_b=envelope_wide <<< 2; end
            12: begin weight_a=envelope_wide <<< 3; weight_b=envelope_wide <<< 2; end
            8: weight_a=envelope_wide <<< 3;
            default: ;
        endcase
    end
    wire signed [41:0] weighted=weight_a+weight_b;
    reg signed [44:0] sum;
    wire signed [20:0] rendered=sum >>> 24;
    integer m;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            loading<=0; load_mode<=0; saved_fc<=0; audible<=0;
            load_half<=0; low_frequency_product<=0;
            for(m=0;m<8;m=m+1) increments[m]<=0;
        end else if(note_on) begin
            loading<=1; load_mode<=0; saved_fc<=fc; load_half<=0;
        end else if(loading) begin
            load_half<=!load_half;
            if(!load_half) low_frequency_product<=product[31:0];
            else begin
                increments[load_mode]<=frequency_product[43:12];
                audible[load_mode]<=frequency_product[47:43]==0;
                if(load_mode==7) loading<=0;
                else load_mode<=load_mode+1'b1;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            cycle<=0; read_level<=0; read_weight<=0; read_audible<=0;
            sum<=0; wave<=0;
            for(m=0;m<8;m=m+1) begin phases[m]<=0; levels[m]<=0; end
        end else if(note_on) begin
            cycle<=0; sum<=0; wave<=0;
            for(m=0;m<8;m=m+1) begin phases[m]<=0; levels[m]<=24'hffffff; end
        end else if(sample_tick) begin
            cycle<=1; sum<=0;
        end else if(cycle!=0) begin
            cycle<=cycle==12 ? 0 : cycle+1'b1;
            if(cycle>=3 && cycle<=10) begin
                phases[mode_index]<=next_phase;
                levels[mode_index]<=next_level;
                read_level<=next_level[23:8];
                read_audible<=DYNAMIC_PITCH ? live_product[47:43]==0 : audible[mode_index];
                case(mode_index)
                    0: read_weight<=72;
                    1: read_weight<=28;
                    2: read_weight<=40;
                    3,4: read_weight<=24;
                    5: read_weight<=20;
                    6: read_weight<=12;
                    7: read_weight<=8;
                endcase
            end
            if(cycle>=4 && cycle<=11)
                sum<=sum+(read_audible ? $signed({{3{weighted[41]}},weighted}) : 45'sd0);
            if(cycle==12) wave<=rendered>32767 ? 16'sh7fff :
                rendered < -32768 ? 16'sh8000 : rendered[15:0];
        end
    end
endmodule

// One mode per clock, with independent lane histories and one shared sine ROM.
module bianzhong_bank #(
    parameter integer LANES=8,
    parameter integer DYNAMIC_PITCH=0
) (
    input wire clk,rst_n,sample_tick,
    input wire [LANES-1:0] note_on,
    input wire [LANES*32-1:0] fcs,
    output wire [LANES*16-1:0] waves
);
    localparam integer INDEX_BITS=LANES>1 ? $clog2(LANES) : 1;
    localparam integer RENDER_CLOCKS=LANES*8;
    reg [7:0] cycle;
    reg [LANES-1:0] cancelled;
    wire render=cycle>=1 && cycle<=RENDER_CLOCKS;
    wire [7:0] slot=render ? cycle-1'b1 : 8'd0;
    wire [INDEX_BITS-1:0] render_lane=slot>>3;
    wire [2:0] render_mode=slot[2:0];
    wire [LANES*256-1:0] phases,increments;
    wire [LANES*192-1:0] levels;
    wire [LANES*8-1:0] audible;
    wire [LANES*32-1:0] saved_fcs;
    reg [31:0] selected_phase;
    reg [23:0] selected_level;
    integer state_slot;
    // Cache one FC per voice, not eight 32-bit increments. A shared product
    // reconstructs the exact approved increment while each mode is rendered.
    generate if(DYNAMIC_PITCH) begin : live_state_selection
    // Keep reduction intermediates local so downstream combinational blocks
    // only observe the completed state, not the accumulator's reset/glitches.
    function [55:0] select_state;
        input [LANES*256-1:0] phase_bus;
        input [LANES*192-1:0] level_bus;
        input [7:0] index;
        reg [55:0] accumulated;
        integer k;
        begin
            accumulated=0;
            for(k=0;k<LANES*8;k=k+1)
                accumulated=accumulated |
                    ({phase_bus[k*32+:32],level_bus[k*24+:24]} &
                     {56{index==k}});
            select_state=accumulated;
        end
    endfunction
    always @(phases or levels or slot) begin
        {selected_phase,selected_level}=select_state(phases,levels,slot);
    end
    end else begin : fixed_state_selection
    always @* begin
        selected_phase=0; selected_level=0;
        for(state_slot=0;state_slot<LANES*8;state_slot=state_slot+1) begin
            selected_phase=selected_phase |
                (phases[state_slot*32+:32] & {32{slot==state_slot}});
            selected_level=selected_level |
                (levels[state_slot*24+:24] & {24{slot==state_slot}});
        end
    end
    end endgenerate
    reg [15:0] live_ratio;
    always @* begin
        case(render_mode)
            0: live_ratio=4096;
            1: live_ratio=6103;
            2: live_ratio=8356;
            3: live_ratio=10977;
            4: live_ratio=15442;
            5: live_ratio=20972;
            6: live_ratio=27976;
            7: live_ratio=33628;
        endcase
    end
    wire [31:0] render_fc=DYNAMIC_PITCH ? fcs[render_lane*32+:32] :
        saved_fcs[render_lane*32+:32];
    wire [47:0] live_product=render_fc*live_ratio;
    wire [31:0] next_phase=selected_phase+live_product[43:12];
    reg [13:0] loss;
    always @* begin
        case(render_mode)
            0,2: loss={7'd0,selected_level[23:17]}+(|selected_level[16:0]);
            1: loss={6'd0,selected_level[23:16]}+(|selected_level[15:0]);
            3: loss={5'd0,selected_level[23:15]}+(|selected_level[14:0]);
            4: loss={4'd0,selected_level[23:14]}+(|selected_level[13:0]);
            5: loss={3'd0,selected_level[23:13]}+(|selected_level[12:0]);
            6: loss={2'd0,selected_level[23:12]}+(|selected_level[11:0]);
            7: loss={1'd0,selected_level[23:11]}+(|selected_level[10:0]);
        endcase
    end
    wire [23:0] next_level=selected_level>loss ? selected_level-loss : 24'd0;
    wire signed [15:0] sine;
    wavetable table_rom(.clk(clk),.addr(next_phase[31:20]),.dout(sine));
    reg read_valid,read_audible;
    reg [INDEX_BITS-1:0] read_lane;
    reg [2:0] read_mode;
    reg [15:0] read_level;
    reg [6:0] read_weight;
    wire signed [17:0] operand_a=$signed(sine);
    wire signed [17:0] operand_b=$signed({2'b0,read_level});
    wire signed [35:0] product=operand_a*operand_b;
    wire signed [32:0] enveloped=product[32:0];
    wire signed [41:0] envelope_wide={{9{enveloped[32]}},enveloped};
    reg signed [41:0] weight_a,weight_b;
    always @* begin
        weight_a=0; weight_b=0;
        case(read_weight)
            72: begin weight_a=envelope_wide <<< 6; weight_b=envelope_wide <<< 3; end
            28: begin weight_a=envelope_wide <<< 5; weight_b=-(envelope_wide <<< 2); end
            40: begin weight_a=envelope_wide <<< 5; weight_b=envelope_wide <<< 3; end
            24: begin weight_a=envelope_wide <<< 4; weight_b=envelope_wide <<< 3; end
            20: begin weight_a=envelope_wide <<< 4; weight_b=envelope_wide <<< 2; end
            12: begin weight_a=envelope_wide <<< 3; weight_b=envelope_wide <<< 2; end
            8: weight_a=envelope_wide <<< 3;
            default: ;
        endcase
    end
    wire signed [41:0] weighted=weight_a+weight_b;
    wire signed [44:0] term=read_audible ? {{3{weighted[41]}},weighted} : 45'sd0;
    reg signed [44:0] sum;
    wire signed [44:0] completed_sum=read_mode==0 ? term : sum+term;
    wire signed [20:0] rendered=completed_sum >>> 24;
    wire signed [15:0] completed_wave=rendered>32767 ? 16'sh7fff :
        rendered < -32768 ? 16'sh8000 : rendered[15:0];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            cycle<=0; cancelled<=0;
            read_valid<=0; read_audible<=0; read_lane<=0; read_mode<=0;
            read_level<=0; read_weight<=0; sum<=0;
        end else begin
            cancelled<=sample_tick ? note_on : cancelled|note_on;
            if(sample_tick) cycle<=1;
            else if(cycle!=0) cycle<=cycle==RENDER_CLOCKS+1 ? 0 : cycle+1'b1;
            read_valid<=render && !sample_tick;
            if(render) begin
                read_lane<=render_lane; read_mode<=render_mode;
                read_level<=next_level[23:8];
                read_audible<=live_product[47:43]==0;
                case(render_mode)
                    0: read_weight<=72;
                    1: read_weight<=28;
                    2: read_weight<=40;
                    3,4: read_weight<=24;
                    5: read_weight<=20;
                    6: read_weight<=12;
                    7: read_weight<=8;
                endcase
            end
            if(read_valid) sum<=completed_sum;
        end
    end
    genvar lane,mode;
    generate for(lane=0;lane<LANES;lane=lane+1) begin : voices
        reg [31:0] saved_fc;
        reg saved_valid;
        reg signed [15:0] wave;
        assign saved_fcs[lane*32+:32]=saved_fc;
        assign waves[lane*16+:16]=wave;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin saved_fc<=0; saved_valid<=0; wave<=0; end
            else if(note_on[lane]) begin
                saved_fc<=fcs[lane*32+:32]; saved_valid<=1; wave<=0;
            end
            else if(read_valid && read_lane==lane && read_mode==7 && !cancelled[lane])
                wave<=completed_wave;
        end
        for(mode=0;mode<8;mode=mode+1) begin : modes
            localparam [15:0] MODE_RATIO=mode==0 ? 4096 : mode==1 ? 6103 :
                mode==2 ? 8356 : mode==3 ? 10977 : mode==4 ? 15442 :
                mode==5 ? 20972 : mode==6 ? 27976 : 33628;
            // Derived debug wires are not used by the render datapath.
            wire [47:0] mode_product=saved_fc*MODE_RATIO;
            wire [31:0] increment=mode_product[43:12];
            wire is_audible=saved_valid && mode_product[47:43]==0;
            reg [31:0] phase;
            reg [23:0] level;
            assign phases[(lane*8+mode)*32+:32]=phase;
            assign increments[(lane*8+mode)*32+:32]=increment;
            assign levels[(lane*8+mode)*24+:24]=level;
            assign audible[lane*8+mode]=is_audible;
            always @(posedge clk or negedge rst_n) begin
                if(!rst_n) begin phase<=0; level<=0; end
                else begin
                    if(note_on[lane]) begin phase<=0; level<=24'hffffff; end
                    else if(render && render_lane==lane && render_mode==mode &&
                            !cancelled[lane] && !sample_tick) begin
                        phase<=next_phase; level<=next_level;
                    end
                end
            end
        end
    end endgenerate
endmodule

// Synchronous mode-state RAM; eight independent modes per voice.
module bianzhong_ram_bank #(
    parameter integer LANES=8,
    parameter integer DYNAMIC_PITCH=0
) (
    input wire clk,rst_n,sample_tick,
    input wire [LANES-1:0] note_on,
    input wire [LANES*32-1:0] fcs,
    input wire [LANES*8-1:0] velocities,
    output wire [LANES*16-1:0] waves
);
    localparam integer INDEX_BITS=LANES>1 ? $clog2(LANES) : 1;
    localparam integer SLOTS=LANES*8;
    localparam integer ADDRESS_BITS=$clog2(SLOTS);
    reg [7:0] cycle;
    reg [LANES-1:0] cancelled;
    reg [LANES-1:0] struck;
    reg [7:0] written [0:LANES-1];
    reg [31:0] cached_fc [0:LANES-1];
    reg [7:0] cached_velocity [0:LANES-1];
    reg signed [15:0] wave [0:LANES-1];
    reg [31:0] phases [0:SLOTS-1];
    reg [23:0] levels [0:SLOTS-1];
    wire render=cycle>=1 && cycle<=SLOTS;
    wire [ADDRESS_BITS-1:0] address=render ? cycle-1'b1 : 0;
    wire [INDEX_BITS-1:0] lane=address>>3;
    wire [2:0] mode=address[2:0];
    reg [31:0] ram_phase;
    reg [23:0] ram_level;
    reg state_valid,state_written,state_struck;
    reg [ADDRESS_BITS-1:0] state_address;
    reg [INDEX_BITS-1:0] state_lane;
    reg [2:0] state_mode;
    reg [31:0] state_fc;
    reg [15:0] state_ratio;
    reg [15:0] ratio;
    always @* begin
        case(mode)
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
    wire [31:0] selected_phase=state_written ? ram_phase : 32'd0;
    // Attenuate upper modes at excitation, without adding render cycles.
    wire [23:0] strike_level = cached_velocity[state_lane] <= 32 ?
        (state_mode < 2 ? 24'hffffff : state_mode == 2 ? 24'hbfffff :
         state_mode < 5 ? 24'h3fffff : 24'h0fffff) :
        cached_velocity[state_lane] <= 90 && state_mode >= 3 ?
        24'hbfffff : 24'hffffff;
    wire [23:0] selected_level=state_written ? ram_level :
        (state_struck ? strike_level : 24'd0);
    wire [47:0] increment_product=state_fc*state_ratio;
    wire [31:0] next_phase=selected_phase+increment_product[43:12];
    reg [13:0] loss;
    always @* begin
        case(state_mode)
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
    wire write_state=rst_n && state_valid && !sample_tick &&
        !cancelled[state_lane] && !note_on[state_lane];
    // No RAM reset: the per-mode written mask invalidates stale histories on
    // reset and every retrigger, including repeated triggers before rendering.
    always @(posedge clk) begin
        ram_phase<=phases[address];
        ram_level<=levels[address];
        if(write_state) begin
            phases[state_address]<=next_phase;
            levels[state_address]<=next_level;
        end
    end
    wire signed [15:0] sine;
    wavetable sine_rom(.clk(clk),.addr(next_phase[31:20]),.dout(sine));
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
        weight_a=0;weight_b=0;
        case(read_weight)
            72: begin weight_a=envelope_wide <<< 6;weight_b=envelope_wide <<< 3;end
            28: begin weight_a=envelope_wide <<< 5;weight_b=-(envelope_wide <<< 2);end
            40: begin weight_a=envelope_wide <<< 5;weight_b=envelope_wide <<< 3;end
            24: begin weight_a=envelope_wide <<< 4;weight_b=envelope_wide <<< 3;end
            20: begin weight_a=envelope_wide <<< 4;weight_b=envelope_wide <<< 2;end
            12: begin weight_a=envelope_wide <<< 3;weight_b=envelope_wide <<< 2;end
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
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            cycle<=0;cancelled<=0;struck<=0;
            state_valid<=0;state_written<=0;state_struck<=0;
            state_address<=0;state_lane<=0;state_mode<=0;state_fc<=0;state_ratio<=4096;
            read_valid<=0;read_audible<=0;read_lane<=0;read_mode<=0;
            read_level<=0;read_weight<=0;sum<=0;
            for(i=0;i<LANES;i=i+1) begin
                written[i]<=0;cached_fc[i]<=0;cached_velocity[i]<=0;wave[i]<=0;
            end
        end else begin
            cancelled<=sample_tick ? note_on : cancelled|note_on;
            if(sample_tick) cycle<=1;
            else if(cycle!=0) cycle<=cycle==SLOTS+2 ? 0 : cycle+1'b1;
            state_valid<=render && !sample_tick;
            if(render) begin
                state_address<=address;state_lane<=lane;state_mode<=mode;
                state_written<=written[lane][mode];state_struck<=struck[lane];
                state_fc<=DYNAMIC_PITCH ? fcs[lane*32+:32] : cached_fc[lane];
                state_ratio<=ratio;
            end
            read_valid<=state_valid && !sample_tick;
            if(state_valid) begin
                read_lane<=state_lane;read_mode<=state_mode;
                read_level<=next_level[23:8];
                read_audible<=increment_product[47:43]==0;
                case(state_mode)
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
            for(i=0;i<LANES;i=i+1) begin
                if(note_on[i]) begin
                    written[i]<=0;struck[i]<=1;cached_fc[i]<=fcs[i*32+:32];wave[i]<=0;
                    cached_velocity[i]<=velocities[i*8+:8];
                end else begin
                    if(write_state && state_lane==i) written[i][state_mode]<=1;
                    if(read_valid && read_lane==i && read_mode==7 && !cancelled[i] &&
                        !sample_tick) wave[i]<=completed_wave;
                end
            end
        end
    end
    genvar v;
    generate for(v=0;v<LANES;v=v+1) begin : outputs
        assign waves[v*16+:16]=wave[v];
    end endgenerate
endmodule

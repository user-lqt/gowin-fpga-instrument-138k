// Synchronous mode-state RAM; eight independent modes per voice.
module bianzhong_ram_bank #(
    parameter integer LANES=8,
    parameter integer DYNAMIC_PITCH=0,
    parameter integer EXTERNAL_PITCH_SELECT=0
) (
    input wire clk,rst_n,sample_tick,
    input wire [LANES-1:0] note_on,
    input wire [LANES*32-1:0] fcs,
    input wire [LANES*8-1:0] velocities,
    output wire [LANES*16-1:0] waves,
    input wire [31:0] selected_fc,
    output wire [(LANES>1 ? $clog2(LANES) : 1)-1:0] pitch_lane
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
    wire [31:0] address_wide=cycle-32'd1;
    wire [ADDRESS_BITS-1:0] address=render ? address_wide[ADDRESS_BITS-1:0] : 0;
    wire [INDEX_BITS-1:0] lane=address>>3;
    assign pitch_lane=lane;
    wire [2:0] mode=address[2:0];
    reg [31:0] ram_phase;
    reg [23:0] ram_level;
    reg state_valid,state_written,state_struck;
    reg [ADDRESS_BITS-1:0] state_address;
    reg [INDEX_BITS-1:0] state_lane;
    reg [2:0] state_mode;
    reg [31:0] state_fc;
    reg [15:0] state_ratio;
    wire [15:0] ratio;
    bell_mode_profile address_profile(.mode(mode),.level(24'd0),
        .ratio(ratio),.weight(),.loss());
    wire [31:0] selected_phase=state_written ? ram_phase : 32'd0;
    wire [23:0] strike_level;
    bell_strike_level u_strike(.velocity(cached_velocity[state_lane]),
        .mode(state_mode),.level(strike_level));
    wire [23:0] selected_level=state_written ? ram_level :
        (state_struck ? strike_level : 24'd0);
    wire [47:0] increment_product=state_fc*state_ratio;
    wire [31:0] next_phase=selected_phase+increment_product[43:12];
    wire [13:0] loss;
    wire [6:0] state_weight;
    bell_mode_profile state_profile(.mode(state_mode),.level(selected_level),
        .ratio(),.weight(state_weight),.loss(loss));
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
    wire signed [41:0] weighted=enveloped*$signed({1'b0,read_weight});
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
            else if(cycle!=0) cycle<=cycle==SLOTS+2 ? 8'd0 : cycle+8'd1;
            state_valid<=render && !sample_tick;
            if(render) begin
                state_address<=address;state_lane<=lane;state_mode<=mode;
                state_written<=written[lane][mode];state_struck<=struck[lane];
                state_fc<=DYNAMIC_PITCH ?
                    (EXTERNAL_PITCH_SELECT ? selected_fc : fcs[lane*32+:32]) : cached_fc[lane];
                state_ratio<=ratio;
            end
            read_valid<=state_valid && !sample_tick;
            if(state_valid) begin
                read_lane<=state_lane;read_mode<=state_mode;
                read_level<=next_level[23:8];
                read_audible<=increment_product[47:43]==0;
                read_weight<=state_weight;
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

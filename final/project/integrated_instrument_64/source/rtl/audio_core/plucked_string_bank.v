// Five-clock visits share string arithmetic and unreset state RAM.
// Each lane keeps its own 2048-sample delay line and noise sequence.
// Karplus-Strong feedback is evaluated per lane; only arithmetic is shared.
// Pitch interpolation, excitation and damping must preserve the signed widths
// below. State packing saves memory without merging different strings' data.
module plucked_string_bank #(
    parameter integer LANES=8,
    parameter integer DYNAMIC_PITCH=1,
    parameter integer DIRECT_STATE_READ=0,
    parameter integer EXTERNAL_PITCH_SELECT=0,
    parameter integer BLOCK_STATE=0,
    parameter integer PACKED_STATE=0
) (
    input wire clk,rst_n,sample_tick,
    input wire [LANES-1:0] note_on,enabled,
    input wire [LANES*32-1:0] fcs,
    input wire [LANES*48-1:0] periods,
    input wire [LANES*8-1:0] velocities,
    output wire [LANES*16-1:0] waves,
    input wire [31:0] pitch_fc,
    input wire [47:0] pitch_period,
    output wire [(LANES>1 ? $clog2(LANES) : 1)-1:0] pitch_lane
);
    localparam integer IB=LANES>1 ? $clog2(LANES) : 1;
    localparam [IB-1:0] LAST_LANE=LANES-1;
    localparam integer STATE_BITS=259;
    // Shallow wide state must not consume full BSRAMs (and SDP split pairs).
    reg [STATE_BITS-1:0] state_ram[0:LANES-1] /* synthesis syn_ramstyle="distributed_ram" */;
    wire [STATE_BITS-1:0] read_state;
    reg [STATE_BITS-1:0] next_state;
    wire signed [15:0] ram_read;
    reg signed [15:0] output_wave[0:LANES-1];
    reg [LANES-1:0] valid,pending_note,pending_sample;
    reg [IB-1:0] lane;
    reg [2:0] step;
    assign pitch_lane=lane;
    generate if(BLOCK_STATE && PACKED_STATE && LANES>=4) begin : packed_state
        string_state_packed_ram #(.LANES(LANES),.WIDTH(STATE_BITS)) storage(
            .clk(clk),.rst_n(rst_n),.step(step),.lane(lane),
            .write_state(next_state),.read_state(read_state));
    end else if(BLOCK_STATE) begin : block_state
        wire [IB-1:0] read_lane=step==4 ?
            (lane==LAST_LANE ? {IB{1'b0}} : lane+1'b1) : lane;
        string_state_ram #(.LANES(LANES),.WIDTH(STATE_BITS)) storage(
            .clk(clk),.write_enable(rst_n && step==4),.write_lane(lane),
            .write_state(next_state),.read_lane(read_lane),.read_state(read_state));
    end else if(DIRECT_STATE_READ) begin : direct_state
        assign read_state=state_ram[lane];
    end else begin : registered_state
        reg [STATE_BITS-1:0] saved /* synthesis syn_keep=1 */;
        always @(posedge clk) saved<=state_ram[lane];
        assign read_state=saved;
    end endgenerate
    reg do_note,do_sample,lane_enabled;
    reg [31:0] fc;
    reg [47:0] period;
    reg [7:0] velocity;
    wire [10:0] pointer,fill_pointer;
    wire [11:0] length,history;
    wire [15:0] fraction,noise,lag_noise;
    wire filling,running,warming;
    wire [11:0] warm_remaining;
    wire signed [16:0] prior_raw,prior_fractional,dc;
    wire [31:0] fill_phase;
    wire signed [16:0] fill_noise,lag_prior,pick_prior;
    wire [15:0] pick_level;
    reg signed [34:0] pick_product;
    localparam [STATE_BITS-1:0] EMPTY_STATE=
        {11'd0,11'd0,12'd2,12'd2,16'd0,16'hace1,16'hace1,
         3'b000,12'd0,17'd0,17'd0,17'd0,32'd0,
         17'd0,17'd0,17'd0,16'd0};
    wire [STATE_BITS-1:0] working_state;
    generate if(BLOCK_STATE && PACKED_STATE && LANES>=4) begin : packed_working_state
        reg [STATE_BITS-1:0] saved;
        always @(posedge clk)
            if(step==1) saved<=valid[lane] ? read_state : EMPTY_STATE;
        assign working_state=saved;
    end else if(DIRECT_STATE_READ) begin : uncached_working_state
        // The lane and its RAM entry stay unchanged through steps 0..4.
        // Reading the entry directly avoids a second 259-bit enabled cache.
        assign working_state=valid[lane] ? read_state : EMPTY_STATE;
    end else begin : cached_working_state
        reg [STATE_BITS-1:0] saved;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) saved<=EMPTY_STATE;
            else if(step==1) saved<=valid[lane] ? read_state : EMPTY_STATE;
        end
        assign working_state=saved;
    end endgenerate
    assign {pointer,fill_pointer,length,history,fraction,noise,lag_noise,
        filling,running,warming,warm_remaining,prior_raw,prior_fractional,
        dc,fill_phase,fill_noise,lag_prior,pick_prior,pick_level}=working_state;

    wire [47:0] corrected_period=period-48'd32768;
    wire [11:0] requested_length=corrected_period[47:16]>2048 ? 12'd2048 :
        corrected_period[27:16]<2 ? 12'd2 : corrected_period[27:16];
    wire [11:0] live_length=requested_length>history ? history : requested_length;
    wire [15:0] live_fraction=DYNAMIC_PITCH ?
        (requested_length>history ? 16'd0 : corrected_period[15:0]) : fraction;
    wire [10:0] read_address=DYNAMIC_PITCH ? pointer-live_length[10:0] : pointer;
    wire signed [16:0] raw=$signed(ram_read);
    wire signed [17:0] delta=prior_raw-raw;
    wire signed [16:0] noise_signed=$signed({noise[15],noise});
    wire signed [16:0] lag_signed=$signed({lag_noise[15],lag_noise});
    wire signed [17:0] noise_pair=noise_signed+fill_noise;
    wire signed [17:0] lag_pair=lag_signed+lag_prior;
    wire signed [17:0] comb_noise=noise_pair-lag_pair;
    wire signed [17:0] pick_difference=filling ? comb_noise : noise_signed-pick_prior;
    wire signed [17:0] multiply_a=step==3 ? delta : pick_difference;
    wire signed [16:0] multiply_b=step==3 ?
        $signed({1'b0,live_fraction}) : $signed({1'b0,pick_level});
    wire signed [34:0] product=multiply_a*multiply_b;
    wire signed [34:0] fractional_sum=
        $signed({{18{raw[16]}},raw})+(product >>> 16);
    reg signed [16:0] fractional_sample;
    wire signed [17:0] pair_sum=
        $signed({fractional_sample[16],fractional_sample})+
        $signed({prior_fractional[16],prior_fractional});
    wire signed [17:0] filtered=pair_sum >>> 1;
    wire signed [17:0] feedback=filtered-(filtered >>> 11);
    wire signed [17:0] dc_difference=
        $signed({fractional_sample[16],fractional_sample})-$signed({dc[16],dc});
    wire signed [16:0] wrapped_difference=dc_difference[16:0];
    wire signed [34:0] output_sum=
        $signed({{17{dc_difference[17]}},dc_difference})+(pick_product >>> 22);
    wire signed [18:0] output_sample=output_sum[18:0];
    wire [16:0] falling_numerator={16'hffff-fill_phase[31:16],1'b0};
    wire [16:0] loss_numerator={1'b0,pick_level}+17'd95;
    wire [11:0] divide_input=do_note ? corrected_period[27:16] :
        filling ? falling_numerator[16:5] : loss_numerator[16:5];
    wire [24:0] divide_note_product=divide_input*13'd3277;
    wire [24:0] divide_loss_product=divide_input*13'd5462;
    wire [24:0] divide_product=do_note ? divide_note_product : divide_loss_product;
    wire [11:0] quotient={1'b0,divide_product[24:14]};
    wire signed [12:0] displacement=fill_phase[31:16]<16384 ?
        $signed({1'b0,fill_phase[31:20]})-13'sd512 :
        $signed({1'b0,quotient})-13'sd512;
    wire signed [18:0] dynamic_noise={{3{pick_product[34]}},pick_product[34:19]};
    wire signed [19:0] excitation=displacement+dynamic_noise;
    wire [6:0] bounded_velocity=velocity>127 ? 7'd127 : velocity[6:0];
    wire [6:0] upper_velocity=bounded_velocity-7'd64;
    wire [6:0] excitation_velocity=bounded_velocity<=64 ?
        bounded_velocity>>1 : 7'd32+upper_velocity+(upper_velocity>>1);
    reg signed [15:0] next_wave;
    reg [10:0] next_pointer,next_fill_pointer;
    reg [11:0] next_length,next_history,next_warm_remaining;
    reg [15:0] next_fraction,next_noise,next_lag_noise,next_pick_level;
    reg next_filling,next_running,next_warming;
    reg signed [16:0] next_prior_raw,next_prior_fractional,next_dc;
    reg signed [16:0] next_fill_noise,next_lag_prior,next_pick_prior;
    reg [31:0] next_fill_phase;
    reg [31:0] selected_fc;
    reg [47:0] selected_period;
    reg [7:0] selected_velocity;
    integer s;
    always @* begin
        selected_fc=0;selected_period=0;selected_velocity=0;
        for(s=0;s<LANES;s=s+1) begin
            selected_fc=selected_fc | (fcs[s*32+:32] & {32{lane==s}});
            selected_period=selected_period | (periods[s*48+:48] & {48{lane==s}});
            selected_velocity=selected_velocity | (velocities[s*8+:8] & {8{lane==s}});
        end
        if(EXTERNAL_PITCH_SELECT) begin
            selected_fc=pitch_fc;
            selected_period=pitch_period;
        end
    end

    always @* begin
        next_pointer=pointer;next_fill_pointer=fill_pointer;
        next_length=length;next_history=history;
        next_fraction=fraction;next_noise=noise;next_lag_noise=lag_noise;
        next_filling=filling;next_running=running;next_warming=warming;
        next_warm_remaining=warm_remaining;
        next_prior_raw=prior_raw;next_prior_fractional=prior_fractional;next_dc=dc;
        next_fill_phase=fill_phase;next_fill_noise=fill_noise;
        next_lag_prior=lag_prior;next_pick_prior=pick_prior;next_pick_level=pick_level;
        next_wave=0;
        if(do_note) begin
            next_pointer=DYNAMIC_PITCH ? requested_length[10:0] : 11'd0;
            next_fill_pointer=0;next_length=requested_length;next_history=requested_length;
            next_fraction=corrected_period[15:0];
            next_noise=16'hace1;next_lag_noise=16'hace1;
            next_filling=1;next_running=1;next_warming=1;
            next_warm_remaining=corrected_period[47:16]>2048 ? 12'd409 :
                corrected_period[47:16]<10 ? 12'd1 : quotient;
            next_prior_raw=0;next_prior_fractional=0;next_dc=0;
            next_fill_phase=0;next_fill_noise=0;next_lag_prior=0;next_pick_prior=0;
            next_pick_level={excitation_velocity,9'd0};next_wave=0;
        end else if(warming) begin
            next_noise={noise[14:0],noise[15]^noise[13]^noise[12]^noise[10]};
            if(warm_remaining<=1) next_warming=0;
            else next_warm_remaining=warm_remaining-1'b1;
        end else if(filling) begin
            next_noise={noise[14:0],noise[15]^noise[13]^noise[12]^noise[10]};
            next_lag_noise={lag_noise[14:0],
                lag_noise[15]^lag_noise[13]^lag_noise[12]^lag_noise[10]};
            next_fill_noise=noise_signed;next_lag_prior=lag_signed;
            next_fill_phase=fill_phase+fc;
            if(fill_pointer==length-1) next_filling=0;
            else next_fill_pointer=fill_pointer+1'b1;
        end else if(do_sample && lane_enabled && running) begin
            next_prior_raw=raw;next_prior_fractional=fractional_sample;
            next_pointer=DYNAMIC_PITCH ? pointer+1'b1 :
                pointer==length-1 ? 11'd0 : pointer+11'd1;
            if(DYNAMIC_PITCH && history<2048) next_history=history+1'b1;
            next_dc=dc+(wrapped_difference >>> 9);
            next_noise={noise[14:0],noise[15]^noise[13]^noise[12]^noise[10]};
            next_pick_prior=noise_signed;next_pick_level=pick_level-quotient;
            next_wave=output_sample>32767 ? 16'sh7fff :
                output_sample< -32768 ? 16'sh8000 : output_sample[15:0];
        end else if(!lane_enabled) next_wave=0;
        next_state={next_pointer,next_fill_pointer,next_length,next_history,
            next_fraction,next_noise,next_lag_noise,next_filling,next_running,next_warming,
            next_warm_remaining,next_prior_raw,next_prior_fractional,next_dc,
            next_fill_phase,next_fill_noise,next_lag_prior,next_pick_prior,next_pick_level};
    end

    wire write_delay=rst_n && step==4 && !do_note && !warming &&
        (filling || (do_sample && lane_enabled && running));
    wire [10:0] write_address=filling ? fill_pointer : pointer;
    wire signed [15:0] write_data=filling ? excitation[15:0] : feedback[15:0];
    generate if(!BLOCK_STATE) begin : distributed_write
        always @(posedge clk)
            if(rst_n && step==4) state_ram[lane]<=next_state;
    end endgenerate

    // Keep each delay line local: no lane bits on the deep RAM address bus.
    wire [LANES*16-1:0] delay_reads;
    reg [15:0] selected_read;
    integer r;
    always @* begin
        selected_read=0;
        for(r=0;r<LANES;r=r+1)
            selected_read=selected_read | (delay_reads[r*16+:16] & {16{lane==r}});
    end
    assign ram_read=selected_read;

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            lane<=0;step<=0;valid<=0;pending_note<=0;pending_sample<=0;
            do_note<=0;do_sample<=0;lane_enabled<=0;
            fc<=0;period<=0;velocity<=0;
            pick_product<=0;fractional_sample<=0;
            for(i=0;i<LANES;i=i+1) output_wave[i]<=0;
        end else begin
            pending_note<=pending_note|(note_on & enabled);
            pending_sample<=pending_sample|{LANES{sample_tick}};
            for(i=0;i<LANES;i=i+1)
                if(note_on[i] || !enabled[i]) output_wave[i]<=0;
            step<=step==4 ? 3'd0 : step+3'd1;
            case(step)
                1: begin
                    do_note<=enabled[lane] && (pending_note[lane] || note_on[lane]);
                    do_sample<=pending_sample[lane] || sample_tick;
                    lane_enabled<=enabled[lane];
                    fc<=selected_fc;period<=selected_period;
                    velocity<=selected_velocity;
                    pending_note[lane]<=0;
                    pending_sample[lane]<=0;
                end
                2: pick_product<=product;
                3: fractional_sample<=fractional_sum[16:0];
                4: begin
                    valid[lane]<=1;
                    // Holding the register avoids a LANES-wide output read mux.
                    if(!pending_note[lane] && !note_on[lane] && enabled[lane] &&
                        (do_note || (!warming && !filling &&
                            ((do_sample && lane_enabled && running) || !lane_enabled))))
                        output_wave[lane]<=next_wave;
                    lane<=lane==LAST_LANE ? {IB{1'b0}} : lane+1'b1;
                end
                default: ;
            endcase
        end
    end
    genvar g;
    generate for(g=0;g<LANES;g=g+1) begin : outputs
        reg signed [15:0] delay_line[0:2047] /* synthesis syn_ramstyle="block_ram" */;
        reg signed [15:0] delay_read;
        always @(posedge clk) begin
            if(step==2 && lane==g) delay_read<=delay_line[read_address];
            if(write_delay && lane==g) delay_line[write_address]<=write_data;
        end
        assign delay_reads[g*16+:16]=delay_read;
        assign waves[g*16+:16]=output_wave[g];
    end endgenerate
endmodule

// Read the next lane during steps 1..4 and write the previous lane during
// steps 0..3. Four narrow rows replace one shallow, 259-bit BSRAM row.
module string_state_packed_ram #(parameter integer LANES=8,WIDTH=259)(
    input wire clk,rst_n,
    input wire [2:0] step,
    input wire [(LANES>1 ? $clog2(LANES) : 1)-1:0] lane,
    input wire [WIDTH-1:0] write_state,
    output wire [WIDTH-1:0] read_state
);
    localparam integer IB=$clog2(LANES);
    localparam integer CHUNK=(WIDTH+3)/4;
    localparam [IB-1:0] LAST_LANE=LANES-1;
    wire [IB-1:0] next_lane=lane==LAST_LANE ? {IB{1'b0}} : lane+1'b1;
    wire [1:0] read_chunk=step[1:0]-2'd1;
    wire [IB+1:0] read_address={next_lane,read_chunk};
    reg [IB-1:0] saved_lane;
    reg [4*CHUNK-1:0] saved_state /* synthesis syn_keep=1 */;
    reg write_valid;
    wire [CHUNK-1:0] read_word;
    reg [4*CHUNK-1:0] assembled /* synthesis syn_keep=1 */;
    wire [CHUNK-1:0] write_word=saved_state[step[1:0]*CHUNK+:CHUNK];
    string_state_ram #(.LANES(LANES*4),.WIDTH(CHUNK)) storage(
        .clk(clk),.write_enable(rst_n && write_valid && step<4),
        .write_lane({saved_lane,step[1:0]}),.write_state(write_word),
        .read_lane(read_address),.read_state(read_word));
    always @(posedge clk) begin
        case(step)
            2: assembled[0*CHUNK+:CHUNK]<=read_word;
            3: assembled[1*CHUNK+:CHUNK]<=read_word;
            4: assembled[2*CHUNK+:CHUNK]<=read_word;
            0: assembled[3*CHUNK+:CHUNK]<=read_word;
            default: ;
        endcase
        if(rst_n && step==4) begin
            saved_lane<=lane;
            saved_state<={{(4*CHUNK-WIDTH){1'b0}},write_state};
        end
    end
    always @(posedge clk or negedge rst_n)
        if(!rst_n) write_valid<=0;
        else if(step==4) write_valid<=1;
    assign read_state=assembled[WIDTH-1:0];
endmodule

module string_state_ram #(parameter integer LANES=8,WIDTH=259)(
    input wire clk,write_enable,
    input wire [(LANES>1 ? $clog2(LANES) : 1)-1:0] write_lane,read_lane,
    input wire [WIDTH-1:0] write_state,
    output reg [WIDTH-1:0] read_state
);
    localparam integer DEPTH=LANES<16 ? 16 : LANES;
    reg [WIDTH-1:0] memory[0:DEPTH-1]
        /* synthesis syn_ramstyle="block_ram" */;
    always @(posedge clk) begin
        read_state<=memory[read_lane];
        if(write_enable) begin
            memory[write_lane]<=write_state;
            if(LANES==1) read_state<=write_state;
        end
    end
endmodule

// Shared envelope update for the canonical allocator contract:
// sample_tick every >= VOICES+4 clocks; note events one clock after tick.
// Outputs settle VOICES+3 clocks after tick, before ranking and gain reads.
module adsr_state_bank #(
    parameter integer VOICES=32,
    parameter integer RELEASE_SAMPLES=4800,
    parameter integer BELL_RING_SAMPLES=192000
) (
    input wire clk, rst_n, sample_tick,
    input wire [VOICES-1:0] note_on, note_off,
    input wire [VOICES*2-1:0] instruments,
    input wire [VOICES*8-1:0] velocities,
    output wire [VOICES*16-1:0] levels,
    output wire [VOICES*3-1:0] stages,
    output wire [VOICES-1:0] active
);
    localparam integer EB=BELL_RING_SAMPLES>65536 ?
        $clog2(BELL_RING_SAMPLES) : 16;
    localparam integer RB=RELEASE_SAMPLES>1 ? $clog2(RELEASE_SAMPLES) : 1;
    localparam integer SB=65535/RELEASE_SAMPLES>0 ?
        $clog2(65535/RELEASE_SAMPLES+1) : 1;
    localparam integer IB=VOICES>1 ? $clog2(VOICES) : 1;
    localparam integer BELL_TAIL_SAMPLES=BELL_RING_SAMPLES<8 ? 1 :
        BELL_RING_SAMPLES/8;
    localparam integer STATE_BITS=EB+16+SB+2*RB;
    localparam [2:0] IDLE=0,ATTACK=1,DECAY=2,SUSTAIN=3,RELEASE=4;
    // Non-reset state memory; IDLE masks uninitialized state after reset.
    reg [STATE_BITS-1:0] state_memory[0:VOICES-1];
    reg [15:0] level_memory[0:VOICES-1];
    reg [2:0] stage_memory[0:VOICES-1];
    reg [VOICES-1:0] on_pending,off_pending;
    reg [IB-1:0] slot;
    reg [1:0] settle;
    reg busy;
    wire update=busy && settle==0;
    wire [1:0] instrument=instruments[slot*2+:2];
    wire [7:0] raw_velocity=velocities[slot*8+:8];
    wire [7:0] velocity=raw_velocity>127 ? 8'd127 : raw_velocity;
    wire [2:0] stage=stage_memory[slot];
    wire [15:0] level=level_memory[slot];
    wire [EB-1:0] elapsed;
    wire [15:0] piano_error;
    wire [SB-1:0] release_step;
    wire [RB-1:0] remainder,error;
    assign {elapsed,piano_error,release_step,remainder,error}=
        stage==IDLE ? {STATE_BITS{1'b0}} : state_memory[slot];
    wire [15:0] attack_length=instrument==0 ?
        (velocity<=32 ? 120 : velocity<=90 ? 96 : 60) :
        instrument==2 ? (velocity<=32 ? 48 : velocity<=90 ? 32 : 24) : 48;
    wire [16:0] attack_step=instrument==0 ?
        (velocity<=32 ? 546 : velocity<=90 ? 683 : 1093) :
        instrument==2 ? (velocity<=32 ? 1366 : velocity<=90 ? 2048 : 2731) : 1366;
    wire [16:0] piano_sum={1'b0,piano_error}+{1'b0,level};
    wire [16:0] piano_step=level>12000 ? piano_sum>>13 : piano_sum>>15;
    wire bell_tail=elapsed>=BELL_RING_SAMPLES-BELL_TAIL_SAMPLES;
    wire [16:0] bell_step=bell_tail ? piano_sum>>12 : piano_sum>>16;
    wire [15:0] bell_error=bell_tail ?
        {4'd0,piano_sum[11:0]} : piano_sum[15:0];
    wire [RB:0] error_sum={1'b0,error}+{1'b0,remainder};
    wire extra=error_sum>=RELEASE_SAMPLES;
    wire [SB:0] release_decrement={1'b0,release_step}+extra;
    wire [15:0] release_decrement_limited=release_decrement;
    wire [RB:0] release_samples_wide=RELEASE_SAMPLES;
    wire [RB:0] next_error_wide=extra ? error_sum-release_samples_wide : error_sum;
    reg [15:0] next_level;
    localparam [15:0] DIVISOR=RELEASE_SAMPLES;
    wire [15:0] next_release_step_wide=next_level/DIVISOR;
    wire [SB-1:0] next_release_step_div=next_release_step_wide[SB-1:0];
    wire [15:0] next_remainder_wide=next_level%DIVISOR;
    wire [RB-1:0] next_remainder_div=next_remainder_wide[RB-1:0];
    wire [16:0] decrement_fade_wide=({1'b0,level}+17'd32767)>>15;
    wire [15:0] decrement_fade=decrement_fade_wide[15:0];
    wire [16:0] decrement_wide=stage==RELEASE ? {1'b0,release_decrement_limited} :
        instrument==0 ? piano_step :
        instrument==2 ? bell_step : {1'b0,decrement_fade};
    wire [15:0] decrement=decrement_wide[15:0];
    wire [16:0] operand=stage==ATTACK ? -attack_step : {1'b0,decrement};
    wire [16:0] stepped={1'b0,level}-operand;
    reg [2:0] next_stage;
    reg [EB-1:0] next_elapsed;
    reg [15:0] next_piano_error;
    reg [SB-1:0] next_release_step;
    reg [RB-1:0] next_remainder,next_error;
    // Release division uses the post-tick level, just as a NOTE_OFF delivered
    // by the allocator on the following clock does in the parallel reference.
    reg [STATE_BITS-1:0] next_state;
    always @* begin
        next_level=level;
        next_stage=stage;
        next_elapsed=elapsed;
        next_piano_error=piano_error;
        next_release_step=release_step;
        next_remainder=remainder;
        next_error=error;
        case(stage)
            ATTACK: begin
                if(elapsed==attack_length-1 || stepped>=65535) begin
                    next_level=65535;next_elapsed=0;next_stage=DECAY;
                end else begin
                    next_level=stepped[15:0];next_elapsed=elapsed+1'b1;
                end
            end
            DECAY: begin
                if(instrument==2) begin
                    if(elapsed==BELL_RING_SAMPLES-1 || {1'b0,level}<=bell_step) begin
                        next_level=0;next_elapsed=0;next_stage=IDLE;
                    end else begin
                        next_elapsed=elapsed+1'b1;
                        next_piano_error=bell_error;
                        next_level=stepped[15:0];
                    end
                end else if(instrument==0) begin
                    next_piano_error=level>12000 ?
                        (piano_sum & 17'd8191) : (piano_sum & 17'd32767);
                    if(level<=1) begin next_level=0;next_stage=SUSTAIN;end
                    else next_level=stepped[15:0];
                end else if(elapsed==59999 || {1'b0,level}<=decrement) begin
                    next_level=0;next_elapsed=0;next_stage=SUSTAIN;
                end else begin
                    next_level=stepped[15:0];next_elapsed=elapsed+1'b1;
                end
            end
            SUSTAIN: begin
                next_level=instrument==2 ? 65535 : 0;
                if(instrument!=2) next_stage=IDLE;
            end
            RELEASE: begin
                if(elapsed==RELEASE_SAMPLES-1) begin
                    next_level=0;next_elapsed=0;next_stage=IDLE;
                end else begin
                    next_level=stepped[15:0];
                    next_error=next_error_wide[RB-1:0];
                    next_elapsed=elapsed+1'b1;
                end
            end
            default: ;
        endcase
        if(on_pending[slot]) begin
            next_level=0;next_piano_error=0;next_elapsed=0;next_stage=ATTACK;
        end else if(off_pending[slot] && next_stage!=IDLE && instrument!=2) begin
            next_elapsed=0;
            if(RELEASE_SAMPLES<=65535) begin
                next_release_step=next_release_step_div;
                next_remainder=next_remainder_div;
            end else begin
                next_release_step=0;next_remainder=next_level;
            end
            next_error=0;next_stage=RELEASE;
        end
        next_state={next_elapsed,next_piano_error,next_release_step,
            next_remainder,next_error};
    end
    always @(posedge clk)
        if(rst_n && update) state_memory[slot]<=next_state;
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            busy<=0;slot<=0;settle<=0;on_pending<=0;off_pending<=0;
            for(i=0;i<VOICES;i=i+1) begin
                level_memory[i]<=0;stage_memory[i]<=IDLE;
            end
        end else if(sample_tick) begin
            busy<=1;slot<=0;settle<=2;on_pending<=0;off_pending<=0;
        end else if(busy) begin
            on_pending<=on_pending|note_on;
            off_pending<=off_pending|note_off;
            if(settle!=0) settle<=settle-1'b1;
            else begin
                level_memory[slot]<=next_level;
                stage_memory[slot]<=next_stage;
                if(slot==VOICES-1) busy<=0;
                else slot<=slot+1'b1;
            end
        end
    end
    genvar lane;
    generate for(lane=0;lane<VOICES;lane=lane+1) begin : outputs
        assign levels[lane*16+:16]=level_memory[lane];
        assign stages[lane*3+:3]=stage_memory[lane];
        assign active[lane]=stage_memory[lane]!=IDLE;
    end endgenerate
endmodule

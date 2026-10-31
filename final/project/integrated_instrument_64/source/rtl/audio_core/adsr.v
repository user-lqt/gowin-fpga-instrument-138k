module adsr #(
    parameter integer ATTACK_SAMPLES  = 480,
    parameter integer DECAY_SAMPLES   = 2400,
    parameter [15:0]  SUSTAIN_LEVEL   = 16'd45875,
    parameter integer RELEASE_SAMPLES = 4800,
    parameter integer ENABLE_TIMBRES = 0,
    parameter integer EXTERNAL_RELEASE = 0,
    parameter integer BELL_RING_SAMPLES = 192000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_tick,
    input  wire        note_on,
    input  wire        note_off,
    input  wire [1:0]  instrument,
    input  wire [7:0]  velocity,
    input  wire [15:0] shared_release_quotient,
    input  wire [15:0] shared_release_modulus,
    output reg  [15:0] level,
    output wire        active,
    output reg  [2:0]  stage
);
    localparam [2:0] IDLE    = 3'd0;
    localparam [2:0] ATTACK  = 3'd1;
    localparam [2:0] DECAY   = 3'd2;
    localparam [2:0] SUSTAIN = 3'd3;
    localparam [2:0] RELEASE = 3'd4;
    localparam integer ATTACK_STEP =
        (65535 + ATTACK_SAMPLES - 1) / ATTACK_SAMPLES;
    localparam integer DECAY_STEP =
        (65535 - SUSTAIN_LEVEL + DECAY_SAMPLES - 1) / DECAY_SAMPLES;
    localparam integer RELEASE_BITS = RELEASE_SAMPLES > 1 ?
        $clog2(RELEASE_SAMPLES) : 1;
    localparam integer STEP_BITS = 65535 / RELEASE_SAMPLES > 0 ?
        $clog2(65535 / RELEASE_SAMPLES + 1) : 1;
    localparam [RELEASE_BITS:0] RELEASE_LIMIT = RELEASE_SAMPLES;
    wire [15:0] attack_length = !ENABLE_TIMBRES ? ATTACK_SAMPLES :
        instrument == 0 ? (velocity<=32 ? 120 : velocity<=90 ? 96 : 60) :
        instrument == 2 ? (velocity<=32 ? 48 : velocity<=90 ? 32 : 24) : 48;
    wire [15:0] decay_length = !ENABLE_TIMBRES ? DECAY_SAMPLES :
        instrument == 0 ? 65535 : instrument == 2 ? 1 : 60000;
    wire [15:0] sustain = !ENABLE_TIMBRES ? SUSTAIN_LEVEL :
        instrument == 2 ? 65535 : 0;
    wire [16:0] attack_step_value = !ENABLE_TIMBRES ? ATTACK_STEP :
        instrument == 0 ? (velocity<=32 ? 546 : velocity<=90 ? 683 : 1093) :
        instrument == 2 ? (velocity<=32 ? 1366 : velocity<=90 ? 2048 : 2731) : 1366;
    wire [16:0] decay_step_value = !ENABLE_TIMBRES ? DECAY_STEP :
        instrument == 2 ? 0 :
        (instrument == 1 || instrument == 3) ?
        (({1'b0, level} + 17'd32767) >> 15) : 1;
    localparam integer ELAPSED_BITS=BELL_RING_SAMPLES>65536 ?
        $clog2(BELL_RING_SAMPLES) : 16;
    localparam integer BELL_TAIL_SAMPLES=BELL_RING_SAMPLES<8 ? 1 :
        BELL_RING_SAMPLES/8;
    reg [ELAPSED_BITS-1:0] elapsed;
    // Share the fractional state: piano uses <=15 bits; bell uses all 16.
    reg [15:0] piano_decay_error;
    wire [16:0] piano_decay_sum = {1'b0, piano_decay_error} + {1'b0, level};
    wire [16:0] piano_decay_step = level > 16'd12000 ?
        (piano_decay_sum >> 13) : (piano_decay_sum >> 15);
    wire bell_tail=elapsed>=BELL_RING_SAMPLES-BELL_TAIL_SAMPLES;
    // Reuse the fractional accumulator: decay starts at the strike, rather
    // than holding full level until a final fade. Only the last eighth settles fast.
    wire [16:0] bell_decay_step=bell_tail ?
        piano_decay_sum >> 12 : piano_decay_sum >> 16;
    wire [15:0] bell_decay_error=bell_tail ?
        {4'd0,piano_decay_sum[11:0]} : piano_decay_sum[15:0];
    reg [STEP_BITS-1:0] release_step;
    reg [RELEASE_BITS-1:0] release_remainder;
    reg [RELEASE_BITS-1:0] release_error;
    wire [RELEASE_BITS:0] release_error_sum =
        {1'b0, release_error} + {1'b0, release_remainder};
    wire release_extra = release_error_sum >= RELEASE_LIMIT;
    wire [STEP_BITS:0] release_decrement =
        {1'b0, release_step} + release_extra;
    // Only one envelope stage runs per tick. Truncation matches level's
    // original 16-bit subtraction in every stage.
    wire [15:0] level_decrement = stage==RELEASE ? release_decrement :
        ENABLE_TIMBRES && instrument==0 ? piano_decay_step :
        ENABLE_TIMBRES && instrument==2 ? bell_decay_step : decay_step_value;
    wire [16:0] level_step_operand=stage==ATTACK ?
        -attack_step_value : {1'b0,level_decrement};
    wire [16:0] stepped_level={1'b0,level}-level_step_operand;
    wire [15:0] decayed_level=stepped_level[15:0];
    wire [STEP_BITS-1:0] release_quotient;
    wire [RELEASE_BITS-1:0] release_modulus;
    generate if (EXTERNAL_RELEASE) begin : shared_division
        assign release_quotient=shared_release_quotient;
        assign release_modulus=shared_release_modulus;
    end else if (RELEASE_SAMPLES <= 65535) begin : bounded_divisor
        localparam [15:0] DIVISOR = RELEASE_SAMPLES;
        assign release_quotient = level / DIVISOR;
        assign release_modulus = level % DIVISOR;
    end else begin : long_release
        assign release_quotient = 0;
        assign release_modulus = level;
    end endgenerate

    assign active = (stage != IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            level <= 16'd0;
            elapsed <= 16'd0;
            piano_decay_error <= 0;
            release_step <= 0;
            release_remainder <= 0;
            release_error <= 0;
            stage <= IDLE;
        end else if (note_on) begin
            if (ENABLE_TIMBRES) level <= 0;
            piano_decay_error <= 0;
            elapsed <= 16'd0;
            stage <= ATTACK;
        end else if (note_off && active && !(ENABLE_TIMBRES && instrument==2)) begin
            elapsed <= 16'd0;
            release_step <= release_quotient;
            release_remainder <= release_modulus;
            release_error <= 0;
            stage <= RELEASE;
        end else if (sample_tick) begin
            case (stage)
                ATTACK: begin
                    if (elapsed == attack_length - 1 ||
                        stepped_level >= 17'd65535) begin
                        level <= 16'hffff;
                        elapsed <= 16'd0;
                        stage <= DECAY;
                    end else begin
                        level <= stepped_level[15:0];
                        elapsed <= elapsed + 16'd1;
                    end
                end
                DECAY: begin
                    if (ENABLE_TIMBRES && instrument == 2) begin
                        // A tap and a hold share the same finite, decaying ring.
                        if(elapsed==BELL_RING_SAMPLES-1 ||
                           {1'b0,level}<=bell_decay_step) begin
                            level<=0;elapsed<=0;stage<=IDLE;
                        end else begin
                            elapsed<=elapsed+1'b1;
                            piano_decay_error<=bell_decay_error;
                            level<=decayed_level;
                        end
                    end else if (ENABLE_TIMBRES && instrument == 0) begin
                        // Measured upright-piano envelope: fast body decay,
                        // then a quieter, slower soundboard/string tail.
                        piano_decay_error <= level > 16'd12000 ?
                            (piano_decay_sum & 17'd8191) :
                            (piano_decay_sum & 17'd32767);
                        if (level <= 1) begin
                            level <= 0;
                            stage <= SUSTAIN;
                        end else begin
                            level <= decayed_level;
                        end
                    end else if (elapsed == decay_length - 1 ||
                        {1'b0, level} <= {1'b0, sustain} + decay_step_value) begin
                        level <= sustain;
                        elapsed <= 16'd0;
                        stage <= SUSTAIN;
                    end else begin
                        level <= decayed_level;
                        elapsed <= elapsed + 16'd1;
                    end
                end
                SUSTAIN: begin
                    level <= sustain;
                    if (ENABLE_TIMBRES && sustain == 0) stage <= IDLE;
                end
                RELEASE: begin
                    if (elapsed == RELEASE_SAMPLES - 1) begin
                        level <= 16'd0;
                        elapsed <= 16'd0;
                        stage <= IDLE;
                    end else begin
                        level <= decayed_level;
                        release_error <= release_extra ?
                            release_error_sum - RELEASE_LIMIT :
                            release_error_sum;
                        elapsed <= elapsed + 16'd1;
                    end
                end
                default: ;
            endcase
        end
    end
endmodule

// One allocator NOTE_OFF selects one envelope; release state stays per voice.
module adsr_release_bank #(
    parameter integer VOICES=32,
    parameter integer RELEASE_SAMPLES=4800
) (
    input wire [VOICES-1:0] note_off,
    input wire [VOICES*16-1:0] levels,
    output wire [15:0] quotient,modulus
);
    reg [15:0] selected_level;
    integer slot;
    always @* begin
        selected_level=0;
        for(slot=0;slot<VOICES;slot=slot+1)
            selected_level=selected_level |
                (levels[slot*16+:16] & {16{note_off[slot]}});
    end
    generate if(RELEASE_SAMPLES<=65535) begin : bounded
        localparam [15:0] DIVISOR=RELEASE_SAMPLES;
        assign quotient=selected_level/DIVISOR;
        assign modulus=selected_level%DIVISOR;
    end else begin : long_release
        assign quotient=0;
        assign modulus=selected_level;
    end endgenerate
endmodule

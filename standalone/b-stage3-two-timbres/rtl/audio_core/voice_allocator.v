`include "event_defs.vh"

module voice_allocator #(
    parameter integer VOICES = 4,
    parameter integer STEAL_ON_FULL = 0,
    parameter integer SHARED_AGE = 0
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  sample_tick,
    input  wire                  event_valid,
    input  wire [1:0]            event_type,
    input  wire [6:0]            note_id,
    input  wire [7:0]            velocity,
    input  wire [1:0]            instrument,
    input  wire [31:0]           note_fc,
    input  wire [47:0]           note_period,
    input  wire [VOICES-1:0]     voice_active,
    input  wire [VOICES*16-1:0]  envelope_levels,
    output reg  [VOICES-1:0]     voice_note_on,
    output reg  [VOICES-1:0]     voice_note_off,
    output reg  [VOICES-1:0]     key_down,
    output reg  [VOICES*7-1:0]   voice_note_id,
    output reg  [VOICES*8-1:0]   voice_velocity,
    output reg  [VOICES*2-1:0]   voice_instrument,
    output reg  [VOICES*32-1:0]  voice_fc,
    output reg  [VOICES*48-1:0]  voice_period,
    output reg                   full_pulse
);
    // event_valid is the one-cycle dequeue pulse from audio_core's event FIFO.
    // This block must not queue the raw B input a second time.

    integer matching;
    integer available;
    integer steal;
    integer target;
    integer k;
    integer j;
    reg [31:0] age [0:VOICES-1];
    localparam integer LEAVES = 1 << $clog2(VOICES);
    localparam integer INDEX_BITS = VOICES > 1 ? $clog2(VOICES) : 1;
    wire [2*LEAVES-1:0] candidate_valid, candidate_key;
    wire [15:0] candidate_level [0:2*LEAVES-1];
    wire [31:0] candidate_age [0:2*LEAVES-1];
    wire [INDEX_BITS-1:0] candidate_index [0:2*LEAVES-1];
    genvar leaf,node;
    generate
        for(leaf=0;leaf<LEAVES;leaf=leaf+1) begin : candidate
            if(leaf<VOICES) begin : real_slot
                assign candidate_valid[LEAVES+leaf]=1;
                assign candidate_key[LEAVES+leaf]=key_down[leaf];
                assign candidate_level[LEAVES+leaf]=envelope_levels[leaf*16+:16];
                assign candidate_age[LEAVES+leaf]=age[leaf];
                assign candidate_index[LEAVES+leaf]=leaf;
            end else begin : padding
                assign candidate_valid[LEAVES+leaf]=0;
                assign candidate_key[LEAVES+leaf]=0;
                assign candidate_level[LEAVES+leaf]=0;
                assign candidate_age[LEAVES+leaf]=0;
                assign candidate_index[LEAVES+leaf]=0;
            end
        end
        // Same lexicographic winner, but five comparator levels for 32 slots.
        for(node=1;node<LEAVES;node=node+1) begin : tournament
            wire take_right=candidate_valid[2*node+1] &&
                (!candidate_valid[2*node] ||
                 (!candidate_key[2*node+1] && candidate_key[2*node]) ||
                 (candidate_key[2*node+1]==candidate_key[2*node] &&
                  (candidate_level[2*node+1]<candidate_level[2*node] ||
                   (candidate_level[2*node+1]==candidate_level[2*node] &&
                    candidate_age[2*node+1]>candidate_age[2*node]))));
            assign candidate_valid[node]=candidate_valid[2*node] || candidate_valid[2*node+1];
            assign candidate_key[node]=take_right ? candidate_key[2*node+1] : candidate_key[2*node];
            assign candidate_level[node]=take_right ? candidate_level[2*node+1] : candidate_level[2*node];
            assign candidate_age[node]=take_right ? candidate_age[2*node+1] : candidate_age[2*node];
            assign candidate_index[node]=take_right ? candidate_index[2*node+1] : candidate_index[2*node];
        end
    endgenerate

    always @(*) begin
        matching = -1;
        available = -1;
        steal = candidate_index[1];
        for (k = 0; k < VOICES; k = k + 1) begin
            if (matching == -1 && key_down[k] &&
                voice_note_id[k*7 +: 7] == note_id)
                matching = k;
            if (available == -1 && !voice_active[k] && !key_down[k])
                available = k;
        end
        target = matching != -1 ? matching : available != -1 ? available : steal;
    end

    wire age_reset = sample_tick && event_valid &&
        event_type == `EVENT_NOTE_ON && velocity != 0 &&
        (matching != -1 || available != -1 || STEAL_ON_FULL);
    generate if(SHARED_AGE) begin : serial_age
        reg busy,skip_valid;
        reg [INDEX_BITS-1:0] slot,skip_slot;
        reg [31:0] selected_age;
        integer a,b;
        always @* begin
            selected_age=0;
            for(a=0;a<VOICES;a=a+1)
                selected_age=selected_age | (age[a] & {32{slot==a}});
        end
        wire [31:0] next_age=selected_age==32'hffffffff ?
            selected_age : selected_age+1'b1;
        // Age is consulted only at sample_tick. Finish all slots before it.
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                busy<=0; slot<=0; skip_valid<=0; skip_slot<=0;
                for(b=0;b<VOICES;b=b+1) age[b]<=0;
            end else if(sample_tick) begin
                busy<=1; slot<=0; skip_valid<=age_reset; skip_slot<=target;
                for(b=0;b<VOICES;b=b+1)
                    if(age_reset && target==b) age[b]<=0;
            end else if(busy) begin
                for(b=0;b<VOICES;b=b+1)
                    if(slot==b && !(skip_valid && skip_slot==b))
                        age[b]<=next_age;
                if(slot==VOICES-1) busy<=0;
                else slot<=slot+1'b1;
            end
        end
    end else begin : parallel_age
        integer a;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n)
                for(a=0;a<VOICES;a=a+1) age[a]<=0;
            else begin
                if(sample_tick)
                    for(a=0;a<VOICES;a=a+1)
                        if(age[a]!=32'hffffffff) age[a]<=age[a]+1'b1;
                if(age_reset) age[target]<=0;
            end
        end
    end endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            voice_note_on    <= {VOICES{1'b0}};
            voice_note_off   <= {VOICES{1'b0}};
            key_down         <= {VOICES{1'b0}};
            voice_note_id    <= {(VOICES*7){1'b0}};
            voice_velocity   <= {(VOICES*8){1'b0}};
            voice_instrument <= {(VOICES*2){1'b0}};
            voice_fc         <= {VOICES{32'd731558}};
            voice_period     <= {VOICES{48'd384760985}};
            full_pulse       <= 1'b0;
        end else begin
            voice_note_on  <= {VOICES{1'b0}};
            voice_note_off <= {VOICES{1'b0}};
            full_pulse     <= 1'b0;
            if (sample_tick && event_valid) begin
                case (event_type)
                    `EVENT_NOTE_ON: begin
                        if (velocity != 0 && matching == -1 && available == -1)
                            full_pulse <= 1'b1;
                        // Constant slices infer a local enable per slot, not
                        // a variable write shifter over the packed pitch bus.
                        for (j = 0; j < VOICES; j = j + 1)
                            if (velocity != 0 && target == j &&
                                (matching != -1 || available != -1 || STEAL_ON_FULL)) begin
                                voice_note_on[j] <= 1'b1;
                                voice_velocity[j*8 +: 8] <= velocity;
                                voice_instrument[j*2 +: 2] <= instrument;
                                key_down[j] <= 1'b1;
                                if (matching == -1) begin
                                    voice_note_id[j*7 +: 7] <= note_id;
                                    voice_fc[j*32 +: 32] <= note_fc;
                                    voice_period[j*48 +: 48] <= note_period;
                                end
                            end
                    end
                    `EVENT_NOTE_OFF: begin
                        for (j = 0; j < VOICES; j = j + 1)
                            if (matching == j) begin
                                voice_note_off[j] <= 1'b1;
                                key_down[j] <= 1'b0;
                            end
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule

module adsr #(
    parameter integer ATTACK_SAMPLES  = 480,
    parameter integer DECAY_SAMPLES   = 2400,
    parameter [15:0]  SUSTAIN_LEVEL   = 16'd45875,
    parameter integer RELEASE_SAMPLES = 4800
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_tick,
    input  wire        note_on,
    input  wire        note_off,
    output reg  [15:0] level,
    output wire        active,
    output reg  [2:0]  stage
);
    localparam [2:0] IDLE    = 3'd0;
    localparam [2:0] ATTACK  = 3'd1;
    localparam [2:0] DECAY   = 3'd2;
    localparam [2:0] SUSTAIN = 3'd3;
    localparam [2:0] RELEASE = 3'd4;

    localparam integer ATTACK_STEP  = (65535 + ATTACK_SAMPLES - 1) / ATTACK_SAMPLES;
    localparam integer DECAY_STEP   = (65535 - SUSTAIN_LEVEL + DECAY_SAMPLES - 1) / DECAY_SAMPLES;
    reg [15:0] elapsed;
    reg [16:0] release_step;
    reg [31:0] release_remainder;
    reg [31:0] release_error;
    wire [31:0] release_error_sum = release_error + release_remainder;
    wire release_extra = release_error_sum >= RELEASE_SAMPLES;
    wire [16:0] release_decrement = release_step + release_extra;

    assign active = (stage != IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            level   <= 16'd0;
            elapsed <= 16'd0;
            release_step <= 17'd0;
            release_remainder <= 32'd0;
            release_error <= 32'd0;
            stage   <= IDLE;
        end else if (note_on) begin
            elapsed <= 16'd0;
            stage   <= ATTACK;
        end else if (note_off && active) begin
            elapsed <= 16'd0;
            // Distribute fractional steps so even a low-level release lasts N ticks.
            release_step <= level / RELEASE_SAMPLES;
            release_remainder <= level % RELEASE_SAMPLES;
            release_error <= 32'd0;
            stage   <= RELEASE;
        end else if (sample_tick) begin
            case (stage)
                ATTACK: begin
                    if (elapsed == ATTACK_SAMPLES - 1 ||
                        {1'b0, level} + ATTACK_STEP >= 17'd65535) begin
                        level   <= 16'hffff;
                        elapsed <= 16'd0;
                        stage   <= DECAY;
                    end else begin
                        level   <= level + ATTACK_STEP;
                        elapsed <= elapsed + 16'd1;
                    end
                end
                DECAY: begin
                    if (elapsed == DECAY_SAMPLES - 1 ||
                        {1'b0, level} <= {1'b0, SUSTAIN_LEVEL} + DECAY_STEP) begin
                        level   <= SUSTAIN_LEVEL;
                        elapsed <= 16'd0;
                        stage   <= SUSTAIN;
                    end else begin
                        level   <= level - DECAY_STEP;
                        elapsed <= elapsed + 16'd1;
                    end
                end
                SUSTAIN: level <= SUSTAIN_LEVEL;
                RELEASE: begin
                    if (elapsed == RELEASE_SAMPLES - 1) begin
                        level   <= 16'd0;
                        elapsed <= 16'd0;
                        stage   <= IDLE;
                    end else begin
                        level   <= level - release_decrement;
                        release_error <= release_extra ?
                            release_error_sum - RELEASE_SAMPLES : release_error_sum;
                        elapsed <= elapsed + 16'd1;
                    end
                end
                default: ;
            endcase
        end
    end
endmodule

//=============================================================================
// voice.v —— A2 单声部封装:振荡器 + ADSR + 力度
//
//   一个 voice 对应一个独立音符。声部处于 IDLE 时 audio=0；
//   空闲声部 NOTE_ON 初始化相位；同音重触发保持相位和当前包络。
//   NOTE_OFF 进入 Release，不硬切。
//=============================================================================
`include "event_defs.vh"

module voice #(
    parameter integer ATTACK_SAMPLES  = 480,
    parameter integer DECAY_SAMPLES   = 2400,
    parameter [15:0]  SUSTAIN_LEVEL   = 16'd45875,
    parameter integer RELEASE_SAMPLES = 4800
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire               note_on,
    input  wire               note_off,
    input  wire [6:0]         note_id,
    input  wire [7:0]         velocity,
    input  wire [1:0]         instrument,
    output wire signed [23:0] audio,
    output wire               active,
    output wire [15:0]        envelope_level,
    output wire [2:0]         envelope_stage
);
    wire [31:0] fc;
    reg [7:0] held_velocity;
    // Retain allocator note IDs so NOTE_OFF matches both strike modes.
    // A slow A-to-B travel is encoded by the low velocity from the decoder.
    wire slow_strike = held_velocity < 8'd92;
    wire [6:0] lowered_note = note_id > 7'd12 ? note_id - 7'd12 : 7'd0;
    wire [6:0] sounding_note = slow_strike ? lowered_note : note_id;
    wire signed [15:0] wave;
    wire signed [15:0] harmonic;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) held_velocity <= 0;
        else if (note_on) held_velocity <= velocity > 127 ? 8'd127 : velocity;
    reg [1:0] held_instrument;
    // A held or releasing note keeps its phase when retriggered.
    wire phase_load = note_on && !active;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) held_instrument <= 0;
        else if (phase_load) held_instrument <= instrument;

    note_to_fc u_note_to_fc (
        .note_id (sounding_note),
        .fc      (fc)
    );

    oscillator u_oscillator (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .phase_load  (phase_load),
        .fc          (fc),
        .instrument  (held_instrument),
        .wave        (wave),
        .harmonic    (harmonic)
    );

    adsr #(
        .ATTACK_SAMPLES  (ATTACK_SAMPLES),
        .DECAY_SAMPLES   (DECAY_SAMPLES),
        .SUSTAIN_LEVEL   (SUSTAIN_LEVEL),
        .RELEASE_SAMPLES (RELEASE_SAMPLES)
    ) u_adsr (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .note_on     (note_on),
        .note_off    (note_off),
        .level       (envelope_level),
        .active      (active),
        .stage       (envelope_stage)
    );

    wire [7:0] safe_velocity = held_velocity;
    // Slow strikes are 40% amplitude; fast strikes use full gain.
    wire [7:0] strike_gain = safe_velocity == 0 ? 8'd0 :
                             slow_strike ? 8'd51 : 8'd127;
    wire signed [8:0]  velocity_ext = $signed({1'b0, strike_gain});
    wire signed [31:0] wave_velocity = wave * velocity_ext;
    wire signed [32:0] velocity_scaled = {wave_velocity, 1'b0};
    wire signed [49:0] envelope_product =
        velocity_scaled * $signed({1'b0, envelope_level});

    assign audio = active ? (envelope_product >>> 16) : 24'sd0;

endmodule

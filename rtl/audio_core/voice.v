//=============================================================================
// voice.v —— A2 单声部封装:振荡器 + ADSR + 力度
//
//   一个 voice 对应一个独立音符。声部处于 IDLE 时 audio=0；
//   NOTE_ON 重新触发相位和包络，NOTE_OFF 进入 Release，不硬切。
//=============================================================================
`include "event_defs.vh"

module voice #(
    parameter integer ENABLE_TIMBRES = 0,
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
    wire signed [15:0] wave;
    wire phase_load = note_on;

    note_to_fc u_note_to_fc (
        .note_id (note_id),
        .fc      (fc)
    );

    reg [15:0] strike_level;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) strike_level <= 0;
        else if (note_on) strike_level <= 16'hffff;
        else if (sample_tick)
            strike_level <= strike_level > 16'd8 ? strike_level - 16'd8 : 0;
    wire [7:0] safe_velocity = velocity > 8'd127 ? 8'd127 : velocity;
    wire [15:0] transient_brightness = safe_velocity * strike_level[15:8];
    wire [7:0] brightness = instrument == 0 ?
        8'd24 + (transient_brightness >> 8) :
        8'd32 + (safe_velocity >> 1);

    oscillator #(.ENABLE_TIMBRES(ENABLE_TIMBRES)) u_oscillator (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .phase_load  (phase_load),
        .fc          (fc),
        .instrument  (instrument),
        .brightness  (brightness),
        .wave        (wave)
    );

    adsr #(
        .ENABLE_TIMBRES  (ENABLE_TIMBRES),
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
        .instrument  (instrument),
        .level       (envelope_level),
        .active      (active),
        .stage       (envelope_stage)
    );

    wire signed [8:0]  velocity_ext = $signed({1'b0, safe_velocity});
    wire signed [31:0] wave_velocity = wave * velocity_ext;
    wire signed [32:0] velocity_scaled = {wave_velocity, 1'b0};
    wire signed [49:0] envelope_product =
        velocity_scaled * $signed({1'b0, envelope_level});

    assign audio = active ? (envelope_product >>> 16) : 24'sd0;

endmodule

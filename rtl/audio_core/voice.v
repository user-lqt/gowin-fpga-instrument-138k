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
    reg [15:0] hammer_lfsr;
    reg signed [17:0] piano_body;
    reg signed [17:0] flute_air_filter;
    reg [15:0] vib_phase;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            strike_level <= 0;
            hammer_lfsr <= 16'h1;
            piano_body <= 0;
            flute_air_filter <= 0;
            vib_phase <= 0;
        end else if (note_on) begin
            strike_level <= 16'hffff;
            hammer_lfsr <= 16'h1;
            piano_body <= 0;
            flute_air_filter <= 0;
            vib_phase <= 0;
        end else if (sample_tick) begin
            strike_level <= ENABLE_TIMBRES && instrument == 0 ?
                (strike_level > 16'd2 ? strike_level -
                    (({1'b0, strike_level} + 17'd1023) >> 10) : 0) :
                (strike_level > 16'd8 ? strike_level - 16'd8 : 0);
            hammer_lfsr <= {hammer_lfsr[14:0],
                            hammer_lfsr[15] ^ hammer_lfsr[13] ^
                            hammer_lfsr[12] ^ hammer_lfsr[10]};
            flute_air_filter <= 0;
            vib_phase <= 0;
            if (instrument == 0 && active)
                piano_body <= piano_body +
                    (($signed({{2{wave[15]}}, wave}) - piano_body) >>> 5);
            else
                piano_body <= 0;
        end
    wire [7:0] safe_velocity = velocity > 8'd127 ? 8'd127 : velocity;
    wire [15:0] transient_brightness = safe_velocity * strike_level[15:8];
    wire [7:0] brightness = instrument == 0 ?
        8'd28 + (transient_brightness >> 8) :
        8'd32 + (safe_velocity >> 1);

    oscillator #(.ENABLE_TIMBRES(ENABLE_TIMBRES)) u_oscillator (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .phase_load  (phase_load),
        .fc          (fc),
        .instrument  (instrument == 1 ? 2'd3 : instrument),
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

    wire signed [15:0] string_wave;
    wire signed [15:0] acoustic_wave;
    generate if (ENABLE_TIMBRES) begin : guitar
        plucked_string u_string (
            .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
            .note_on(note_on),
            .enabled((instrument == 1 || instrument == 3) && note_id >= 24),
            .fc(fc), .velocity(safe_velocity), .wave(string_wave)
        );
        guitar_body u_body (
            .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
            .note_on(note_on), .string_wave(string_wave), .wave(acoustic_wave)
        );
    end else begin : no_guitar
        assign string_wave = 0;
        assign acoustic_wave = 0;
    end endgenerate
    wire signed [15:0] base_rendered_wave =
        ENABLE_TIMBRES && (instrument == 1 || instrument == 3) && note_id >= 24 ?
        acoustic_wave : wave;
    wire signed [15:0] rendered_wave = base_rendered_wave;
    wire signed [15:0] hammer_noise = $signed(hammer_lfsr);
    wire signed [33:0] hammer_product =
        hammer_noise * $signed({1'b0, safe_velocity}) *
        $signed({1'b0, strike_level[15:8]});
    wire signed [23:0] legacy_hammer_product = hammer_product[23:0];
    // Keep the filtered body contribution supportive rather than dominant;
    // the acoustic-piano attack should remain audible over the sustain.
    wire signed [17:0] piano_body_scaled = piano_body >>> 3;
    wire signed [17:0] piano_hammer_scaled =
        instrument == 0 ? (ENABLE_TIMBRES ? (hammer_product >>> 24) :
            (legacy_hammer_product >>> 18)) : 18'sd0;
    wire signed [17:0] piano_excitation =
        $signed({{2{rendered_wave[15]}}, rendered_wave}) +
        (instrument == 0 ? piano_body_scaled : 18'sd0) +
        piano_hammer_scaled;
    wire signed [15:0] piano_wave = piano_excitation > 18'sd32767 ? 16'sh7fff :
        piano_excitation < -18'sd32768 ? 16'sh8000 : piano_excitation[15:0];
    wire signed [8:0]  velocity_ext = $signed({1'b0, safe_velocity});
    wire signed [31:0] wave_velocity = piano_wave * velocity_ext;
    wire signed [32:0] velocity_scaled = {wave_velocity, 1'b0};
    wire signed [49:0] envelope_product =
        velocity_scaled * $signed({1'b0, envelope_level});

    assign audio = active ? (envelope_product >>> 16) : 24'sd0;

endmodule

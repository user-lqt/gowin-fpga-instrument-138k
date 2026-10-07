//=============================================================================
// voice.v —— A2 单声部封装:振荡器 + ADSR + 力度
//
//   一个 voice 对应一个独立音符。声部处于 IDLE 时 audio=0；
//   NOTE_ON 重新触发相位和包络，NOTE_OFF 进入 Release，不硬切。
//=============================================================================
`include "event_defs.vh"

module voice #(
    parameter integer ENABLE_TIMBRES = 0,
    parameter integer ENABLE_GUITAR = 0,
    parameter integer DYNAMIC_PITCH = 0,
    parameter integer EXTERNAL_PITCH = 0,
    parameter integer SHARED_BODY = 0,
    parameter integer SHARED_GAIN = 0,
    parameter integer SHARED_BELL = 0,
    parameter integer SHARED_OSCILLATOR = 0,
    parameter integer SHARED_RELEASE = 0,
    parameter integer OSCILLATOR_LANES = 8,
    parameter integer OSCILLATOR_LANE = 0,
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
    input  wire [31:0]        pitch_fc,
    input  wire [47:0]        pitch_period,
    input wire [15:0] shared_release_quotient,
    input wire [15:0] shared_release_modulus,
    input  wire signed [15:0] body_wave,
    input  wire signed [15:0] bell_bank_wave,
    input wire [6:0] oscillator_cycle,
    input wire signed [15:0] oscillator_lookup,
    input wire signed [26:0] oscillator_product,
    output wire [11:0] oscillator_address,
    output wire signed [17:0] oscillator_operand,
    output wire [7:0] oscillator_gain,
    output wire signed [15:0] body_string_wave,
    input wire [3:0] gain_step,
    input wire signed [44:0] gain_product,
    output wire signed [26:0] gain_operand_a,
    output wire signed [17:0] gain_operand_b,
    output wire signed [23:0] audio,
    output wire               active,
    output wire [15:0]        envelope_level,
    output wire [2:0]         envelope_stage
);
    wire [31:0] fc;
    wire signed [15:0] wave;
    wire phase_load = note_on;

    generate if(EXTERNAL_PITCH) begin : external_pitch
        assign fc=pitch_fc;
    end else begin : local_pitch
    note_to_fc u_note_to_fc (
        .note_id (note_id),
        .fc      (fc)
    );
    end endgenerate

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
    // Keep expressive spectra independent of the audible gain floor.
    wire [7:0] strike_gain = safe_velocity == 0 ? 0 :
        safe_velocity <= 32 ? 64 : safe_velocity <= 90 ? 96 : 127;
    wire [15:0] transient_brightness;
    wire [7:0] brightness = instrument == 0 ?
        (safe_velocity <= 32 ? 8'd16 + (transient_brightness >> 9) :
         safe_velocity <= 90 ? 8'd32 + (transient_brightness >> 8) :
         8'd80 + (transient_brightness >> 8)) :
        8'd32 + (safe_velocity >> 1);

    oscillator #(.ENABLE_TIMBRES(ENABLE_TIMBRES),
        .SHARED_ARITHMETIC(SHARED_OSCILLATOR),
        .BANK_LANES(OSCILLATOR_LANES),.BANK_LANE(OSCILLATOR_LANE)) u_oscillator (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .phase_load  (phase_load),
        .fc          (fc),
        .instrument  (instrument == 1 ? 2'd3 : instrument),
        .brightness  (brightness),
        .bank_cycle(oscillator_cycle),
        .bank_lookup_wave(oscillator_lookup),
        .bank_product(oscillator_product),
        .bank_address(oscillator_address),
        .bank_operand(oscillator_operand),
        .bank_gain(oscillator_gain),
        .wave        (wave)
    );

    adsr #(
        .ENABLE_TIMBRES  (ENABLE_TIMBRES),
        .EXTERNAL_RELEASE (SHARED_RELEASE),
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
        .velocity    (safe_velocity),
        .shared_release_quotient(shared_release_quotient),
        .shared_release_modulus(shared_release_modulus),
        .level       (envelope_level),
        .active      (active),
        .stage       (envelope_stage)
    );

    wire signed [15:0] string_wave;
    wire signed [15:0] acoustic_wave;
    assign body_string_wave=string_wave;
    generate if (ENABLE_TIMBRES && ENABLE_GUITAR) begin : guitar
        wire [47:0] period_q16;
        if(EXTERNAL_PITCH) begin : external_period
            assign period_q16=pitch_period;
        end else begin : local_period
            note_to_period u_period (.note_id(note_id), .period_q16(period_q16));
        end
        plucked_string #(.DYNAMIC_PITCH(DYNAMIC_PITCH)) u_string (
            .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
            .note_on(note_on),
            .enabled((instrument == 1 || instrument == 3) && note_id >= 24),
            .fc(fc), .period_q16(period_q16),
            .velocity(safe_velocity), .wave(string_wave)
        );
        if(SHARED_BODY) begin : external_body
            assign acoustic_wave=body_wave;
        end else begin : internal_body
        guitar_body u_body (
            .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
            .note_on(note_on), .string_wave(string_wave), .wave(acoustic_wave)
        );
        end
    end else begin : no_guitar
        assign string_wave = 0;
        assign acoustic_wave = 0;
    end endgenerate
    wire signed [15:0] base_rendered_wave =
        ENABLE_TIMBRES && ENABLE_GUITAR && (instrument == 1 || instrument == 3) && note_id >= 24 ?
        acoustic_wave : wave;
    wire signed [15:0] bell_wave;
    generate if(SHARED_BELL) begin : external_bell
        assign bell_wave=bell_bank_wave;
    end else begin : internal_bell
    bianzhong #(.DYNAMIC_PITCH(DYNAMIC_PITCH)) u_bell (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .note_on(note_on && ENABLE_TIMBRES && instrument == 2),
        .fc(fc), .velocity(safe_velocity), .wave(bell_wave)
    );
    end endgenerate
    wire signed [15:0] rendered_wave =
        ENABLE_TIMBRES && instrument == 2 ? bell_wave : base_rendered_wave;
    wire signed [15:0] hammer_noise = $signed(hammer_lfsr);
    wire signed [33:0] hammer_product;
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
    generate if (ENABLE_TIMBRES) begin : serial_gain
        reg [3:0] local_cycle;
        wire [3:0] cycle=SHARED_GAIN ? gain_step : local_cycle;
        reg [15:0] transient;
        reg signed [33:0] hammer;
        reg signed [23:0] velocity_product, result;
        reg signed [26:0] operand_a;
        reg signed [17:0] operand_b;
        wire signed [44:0] product;
        if(SHARED_GAIN) begin : external_product
            assign product=gain_product;
        end else begin : internal_product
            assign product=operand_a*operand_b;
        end
        assign gain_operand_a=operand_a;
        assign gain_operand_b=operand_b;
        assign transient_brightness = transient;
        assign hammer_product = hammer;
        always @* begin
            case (cycle)
                2: begin
                    operand_a = $signed({1'b0,safe_velocity});
                    operand_b = $signed({1'b0,strike_level[15:8]});
                end
                3: begin
                    operand_a = hammer_noise;
                    operand_b = $signed({1'b0,transient});
                end
                14: begin
                    operand_a = piano_wave;
                    operand_b = $signed({1'b0,strike_gain});
                end
                default: begin
                    operand_a = $signed({velocity_product,1'b0});
                    operand_b = $signed({1'b0,envelope_level});
                end
            endcase
        end
        // Private oscillator: 13/14/15; shared oscillator: <=45/70/74.
        // Shared bank steps keep the same arithmetic at the later deadlines.
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                local_cycle <= 0; transient <= 0; hammer <= 0;
                velocity_product <= 0; result <= 0;
            end else if (sample_tick) local_cycle <= 1;
            else if (cycle != 0) begin
                local_cycle <= local_cycle == 15 ? 0 : local_cycle + 1'b1;
                case (cycle)
                    2: transient <= product[15:0];
                    3: hammer <= product[33:0];
                    14: velocity_product <= product[23:0];
                    15: result <= product >>> 16;
                endcase
            end
        end
        assign audio = active ? result : 24'sd0;
    end else begin : legacy_gain
        assign gain_operand_a=0;
        assign gain_operand_b=0;
        assign transient_brightness = safe_velocity * strike_level[15:8];
        assign hammer_product = hammer_noise * $signed({1'b0,safe_velocity}) *
            $signed({1'b0,strike_level[15:8]});
        wire signed [8:0] velocity_ext = $signed({1'b0,safe_velocity});
        wire signed [31:0] wave_velocity = piano_wave * velocity_ext;
        wire signed [32:0] velocity_scaled = {wave_velocity,1'b0};
        wire signed [49:0] envelope_product =
            velocity_scaled * $signed({1'b0,envelope_level});
        assign audio = active ? (envelope_product >>> 16) : 24'sd0;
    end endgenerate

endmodule

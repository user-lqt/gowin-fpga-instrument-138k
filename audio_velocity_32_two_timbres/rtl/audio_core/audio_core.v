//=============================================================================
// audio_core.v - A3 defaults; A1/A2 remain explicit regression configurations.
//
//   事件输入(B) -> 音高查表 -> 振荡器 -> 力度/音量 -> 采样输出(C)
//
//   采样域:每个 sample_tick(48 kHz)更新一次音频状态。
//   流水线:phase(1 拍) -> ROM(1 拍) -> 输出寄存器(1 拍),共 3 拍固定延迟,
//           与音高无关,不影响相位连续性。
//
//   A2 默认接入四声部、独立ADSR和饱和混音;A1路径只用于回归。
//   合规:全部样本由本模块逐样本实时计算,无任何预录 PCM。
//=============================================================================
`include "event_defs.vh"

module audio_core #(
    parameter integer ENABLE_POLYPHONY = 1,
    parameter integer VOICE_COUNT = 32,
    parameter integer ENABLE_STEAL = 1,
    parameter integer ENABLE_TIMBRES = 1,
    parameter integer ENABLE_GUITAR = 0,
    parameter integer SHARE_VOICE_ARITHMETIC = 1,
    parameter integer ENABLE_EXPRESSION = 0,
    parameter integer EVENT_DEPTH = 64,
    parameter integer ATTACK_SAMPLES = 480,
    parameter integer DECAY_SAMPLES = 2400,
    parameter [15:0] SUSTAIN_LEVEL = 16'd45875,
    parameter integer RELEASE_SAMPLES = 4800
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,

    // B -> A:演奏事件
    input  wire               event_valid,
    input  wire [1:0]         event_type,
    input  wire [6:0]         note_id,
    input  wire [7:0]         velocity,

    // B -> A:连续表情参数
    input  wire               param_valid,
    input  wire [3:0]         param_id,
    input  wire [15:0]        param_value,

    // A -> C:音频采样与状态
    output reg                audio_core_valid,
    output reg  signed [23:0] audio_left,
    output reg  signed [23:0] audio_right,

    output wire [5:0]         active_voice_count,
    output wire               engine_ready,
    output reg                overload_flag,
    output wire               event_overflow,
    output wire               param_overflow
);

    //-------------------------------------------------------------------------
    // 就绪:上电后等待波表/参数初始化(此处用固定周期模拟)
    //-------------------------------------------------------------------------
    localparam [5:0] INIT_CYCLES = 6'd63;

    reg [5:0] init_cnt;
    reg       ready_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init_cnt <= 6'd0;
            ready_r  <= 1'b0;
        end else if (!ready_r) begin
            init_cnt <= init_cnt + 6'd1;
            if (init_cnt == INIT_CYCLES)
                ready_r <= 1'b1;
        end
    end

    assign engine_ready = ready_r;

    // B/C must pace bursts to fit the finite input queues; no ready signal exists.
    localparam integer PARAM_DEPTH = 4;
    localparam integer EVENT_PTR_BITS = $clog2(EVENT_DEPTH);
    localparam integer A3_MODE = ENABLE_POLYPHONY && ENABLE_TIMBRES;
    localparam integer SHARED_ARITHMETIC = A3_MODE && SHARE_VOICE_ARITHMETIC;
    localparam integer GAIN_LANES = VOICE_COUNT < 4 ? VOICE_COUNT : 4;
    localparam integer BODY_LANES = VOICE_COUNT < 8 ? VOICE_COUNT : 8;
    // Body outputs use the preceding frame's filter state, so the filter
    // recurrence may finish after gain processing but before the next tick.
    localparam integer FILTER_LANES = VOICE_COUNT < 16 ? VOICE_COUNT : 16;
    localparam integer MIX_START = SHARED_ARITHMETIC ? 69+GAIN_LANES : 14;
    localparam integer AUDIO_LATENCY = A3_MODE ? VOICE_COUNT + MIX_START + 4 : 3;
    localparam [15:0] DEFAULT_VOLUME = A3_MODE ? 16'h0fff :
                                      ENABLE_POLYPHONY ? 16'h3fff : 16'hffff;
    reg [AUDIO_LATENCY-1:0] tick_sr;

    reg [1:0]  ev_type_q [0:EVENT_DEPTH-1];
    reg [6:0]  ev_note_q [0:EVENT_DEPTH-1];
    reg [7:0]  ev_vel_q  [0:EVENT_DEPTH-1];
    reg [EVENT_PTR_BITS-1:0] ev_rd;
    reg [EVENT_PTR_BITS-1:0] ev_wr;
    reg [EVENT_PTR_BITS:0] ev_count;
    reg        ev_overflow;

    reg [3:0]  p_id_q  [0:PARAM_DEPTH-1];
    reg [15:0] p_val_q [0:PARAM_DEPTH-1];
    reg [1:0]  p_rd;
    reg [1:0]  p_wr;
    reg [2:0]  p_count;
    reg        p_overflow;

    wire ev_pop = sample_tick && (ev_count != 0) && !ev_overflow;
    wire ev_bypass = sample_tick && (ev_count == 0) && event_valid && !ev_overflow;
    wire ev_fault = event_valid && !ev_overflow && !ev_pop &&
                    (ev_count == EVENT_DEPTH);
    wire ev_push = event_valid && !ev_overflow && !ev_bypass && !ev_fault;
    wire p_pop = sample_tick && (p_count != 0);
    wire p_bypass = sample_tick && (p_count == 0) && param_valid;
    wire p_push = param_valid && !p_bypass &&
                  (p_count < PARAM_DEPTH || p_pop);

    wire [1:0]  selected_type = ev_bypass ? event_type : ev_type_q[ev_rd];
    wire [6:0]  selected_note = ev_bypass ? note_id : ev_note_q[ev_rd];
    wire [7:0]  selected_vel  = ev_bypass ? velocity : ev_vel_q[ev_rd];
    wire [3:0]  selected_param_id  = p_bypass ? param_id : p_id_q[p_rd];
    wire [15:0] selected_param_val = p_bypass ? param_value : p_val_q[p_rd];

    reg [6:0]  cur_note;
    reg [7:0]  cur_vel;
    reg        note_active;
    reg [15:0] volume;
    reg [15:0] volume_target;
    reg [1:0]  instrument;

    reg        phase_load_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ev_rd        <= 4'd0;
            ev_wr        <= 4'd0;
            ev_count     <= 5'd0;
            ev_overflow  <= 1'b0;
            p_rd         <= 2'd0;
            p_wr         <= 2'd0;
            p_count      <= 3'd0;
            p_overflow   <= 1'b0;
            cur_note     <= 7'd0;
            cur_vel      <= 8'd0;
            note_active  <= 1'b0;
            volume       <= DEFAULT_VOLUME;
            volume_target <= DEFAULT_VOLUME;
            instrument   <= 2'd0;
            phase_load_r <= 1'b0;
        end else begin
            phase_load_r <= 1'b0;

            if (ev_fault) begin
                ev_overflow  <= 1'b1;
                ev_rd        <= 4'd0;
                ev_wr        <= 4'd0;
                ev_count     <= 5'd0;
                cur_note     <= 7'd0;
                cur_vel      <= 8'd0;
                note_active  <= 1'b0;
                phase_load_r <= 1'b0;
            end else if (!ev_overflow) begin
                if (ev_push) begin
                    ev_type_q[ev_wr] <= event_type;
                    ev_note_q[ev_wr] <= note_id;
                    ev_vel_q[ev_wr]  <= velocity;
                    ev_wr <= ev_wr == EVENT_DEPTH-1 ? 0 : ev_wr + 1'b1;
                end
                if (ev_pop)
                    ev_rd <= ev_rd == EVENT_DEPTH-1 ? 0 : ev_rd + 1'b1;
                case ({ev_push, ev_pop})
                    2'b10: ev_count <= ev_count + 5'd1;
                    2'b01: ev_count <= ev_count - 5'd1;
                    default: ;
                endcase
                if (sample_tick && (ev_pop || ev_bypass)) begin
                    case (selected_type)
                        `EVENT_NOTE_ON: begin
                            if (selected_vel != 8'd0) begin
                                cur_note     <= selected_note;
                                cur_vel      <= selected_vel;
                                note_active  <= 1'b1;
                                phase_load_r <= 1'b1;
                            end
                        end
                        `EVENT_NOTE_OFF: begin
                            if (selected_note == cur_note)
                                note_active <= 1'b0;
                        end
                        default: ;
                    endcase
                end
            end

            if (p_push) begin
                p_id_q[p_wr]  <= param_id;
                p_val_q[p_wr] <= param_value;
                p_wr <= p_wr + 2'd1;
            end else if (param_valid && !p_bypass) begin
                p_overflow <= 1'b1;
            end
            if (p_pop)
                p_rd <= p_rd + 2'd1;
            case ({p_push, p_pop})
                2'b10: p_count <= p_count + 3'd1;
                2'b01: p_count <= p_count - 3'd1;
                default: ;
            endcase

            if (sample_tick && (p_pop || p_bypass) &&
                selected_param_id == `PARAM_VOLUME) begin
                volume_target <= selected_param_val;
                if (!A3_MODE) volume <= selected_param_val;
            end
            if (A3_MODE && sample_tick) begin
                if (volume < volume_target)
                    volume <= volume_target - volume > 16'd64 ?
                              volume + 16'd64 : volume_target;
                else if (volume > volume_target)
                    volume <= volume - volume_target > 16'd64 ?
                              volume - 16'd64 : volume_target;
            end
            if (sample_tick && (p_pop || p_bypass) &&
                selected_param_id == `PARAM_INSTRUMENT)
                instrument <= !ENABLE_GUITAR ?
                              (selected_param_val == 16'd2 ? 2'd2 : 2'd0) :
                              selected_param_val > 16'd3 ? 2'd0 : selected_param_val[1:0];
        end
    end

    //-------------------------------------------------------------------------
    // 振荡器链:note -> fc -> 相位累加 -> 波表
    //-------------------------------------------------------------------------
    generate if (!ENABLE_POLYPHONY) begin : a1
    wire [31:0]       cur_fc;
    wire signed [15:0] wave;

    note_to_fc u_note_to_fc (
        .note_id (cur_note),
        .fc      (cur_fc)
    );

    oscillator u_oscillator (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .phase_load  (phase_load_r),
        .fc          (cur_fc),
        .instrument  (2'd0),
        .brightness  (8'd0),
        .wave        (wave)
    );

    //-------------------------------------------------------------------------
    // 力度 + 总音量
    //   wave(±32767) * velocity(0..127) << 1  => 峰值 8.32M < 24 位满量程 8.39M
    //   再由 16 位总音量归一化(右移 16)。
    //-------------------------------------------------------------------------
    wire signed [23:0] wave_ext   = {{8{wave[15]}}, wave};
    wire signed [8:0]  vel_ext    = $signed({1'b0, cur_vel});
    wire signed [31:0] vel_prod   = wave_ext * vel_ext;
    wire signed [23:0] vel_scaled = vel_prod[23:0] <<< 1;

    wire signed [39:0] vol_prod   = vel_scaled * $signed({1'b0, volume});
    wire signed [23:0] smp24      = vol_prod[39:16];

    wire gate = ready_r & note_active & !ev_overflow & !ev_fault;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            audio_left  <= 24'sd0;
            audio_right <= 24'sd0;
        end else begin
            audio_left  <= gate ? smp24 : 24'sd0;
            audio_right <= gate ? smp24 : 24'sd0;
        end
    end

    //-------------------------------------------------------------------------
    // 输出有效标志:与输出寄存器同拍(把 sample_tick 延迟 3 拍)
    //-------------------------------------------------------------------------
    //-------------------------------------------------------------------------
    // 状态输出
    //-------------------------------------------------------------------------
    assign active_voice_count = (note_active && !ev_overflow && !ev_fault) ? 6'd1 : 6'd0;

    // A1 单声部峰值恒小于满量程,不会饱和;饱和检测在 A2 混音级引入。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) overload_flag <= 1'b0;
        else        overload_flag <= 1'b0;
    end
    end else begin : a2
        wire [VOICE_COUNT-1:0] voice_active;
        wire [VOICE_COUNT-1:0] voice_note_on;
        wire [VOICE_COUNT-1:0] voice_note_off;
        wire [VOICE_COUNT-1:0] key_down;
        wire [VOICE_COUNT*7-1:0] voice_note_id;
        wire [VOICE_COUNT*8-1:0] voice_velocity;
        wire [VOICE_COUNT*2-1:0] voice_instrument;
        wire [VOICE_COUNT*32-1:0] voice_fc;
        wire [VOICE_COUNT*48-1:0] voice_period;
        wire [VOICE_COUNT*32-1:0] rendered_fc;
        wire [VOICE_COUNT*48-1:0] rendered_period;
        if(ENABLE_EXPRESSION && A3_MODE) begin : expression
            pitch_expression_bank #(.VOICES(VOICE_COUNT)) u_pitch(
                .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
                .param_valid(sample_tick && (p_pop || p_bypass)),
                .param_id(selected_param_id),.param_value(selected_param_val),
                .note_on(voice_note_on),.notes(voice_note_id),
                .base_fcs(voice_fc),.base_periods(voice_period),
                .fcs(rendered_fc),.periods(rendered_period),.busy());
        end else begin : fixed_pitch
            assign rendered_fc=voice_fc;
            assign rendered_period=voice_period;
        end
        wire [31:0] selected_fc;
        wire [47:0] selected_period;
        note_to_fc shared_fc (.note_id(selected_note),.fc(selected_fc));
        note_to_period shared_period (.note_id(selected_note),.period_q16(selected_period));
        wire [VOICE_COUNT*24-1:0] voice_samples;
        wire [VOICE_COUNT*16-1:0] body_string_waves,body_waves;
        wire [VOICE_COUNT*16-1:0] bell_waves;
        wire [VOICE_COUNT-1:0] bell_note_on;
        wire [VOICE_COUNT*12-1:0] oscillator_addresses;
        wire [VOICE_COUNT*18-1:0] oscillator_operands;
        wire [VOICE_COUNT*8-1:0] oscillator_gains;
        wire [VOICE_COUNT*7-1:0] oscillator_cycles;
        wire [VOICE_COUNT*16-1:0] oscillator_lookups;
        wire [VOICE_COUNT*27-1:0] oscillator_products;
        wire [VOICE_COUNT*27-1:0] gain_operands_a;
        wire [VOICE_COUNT*18-1:0] gain_operands_b;
        wire [VOICE_COUNT*4-1:0] gain_steps;
        wire [VOICE_COUNT*45-1:0] gain_products;
        wire [VOICE_COUNT*16-1:0] envelope_levels;
        wire [VOICE_COUNT*3-1:0] envelope_stages;
        wire [15:0] shared_release_quotient,shared_release_modulus;
        wire full_pulse;
        wire signed [23:0] mixed_audio;
        wire mixed_overload;
        wire gate = ready_r && !ev_overflow && !ev_fault;
        reg [5:0] voice_count;
        integer i;

        voice_allocator #(
            .VOICES(VOICE_COUNT),
            .STEAL_ON_FULL(ENABLE_STEAL),
            .SHARED_AGE(SHARED_ARITHMETIC)
        ) u_allocator (
            .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
            .event_valid(ev_pop || ev_bypass),
            .event_type(selected_type), .note_id(selected_note),
            .velocity(selected_vel), .voice_active(voice_active),
            .instrument(instrument),
            .note_fc(selected_fc),.note_period(selected_period),
            .envelope_levels(envelope_levels),
            .voice_note_on(voice_note_on), .voice_note_off(voice_note_off),
            .key_down(key_down), .voice_note_id(voice_note_id),
            .voice_velocity(voice_velocity), .voice_instrument(voice_instrument),
            .voice_fc(voice_fc),.voice_period(voice_period),
            .full_pulse(full_pulse)
        );

        genvar v,bank;
        if(SHARED_ARITHMETIC) begin : release_division
            adsr_release_bank #(.VOICES(VOICE_COUNT),
                .RELEASE_SAMPLES(RELEASE_SAMPLES)) u_bank(
                .note_off(voice_note_off),.levels(envelope_levels),
                .quotient(shared_release_quotient),
                .modulus(shared_release_modulus));
        end else begin : private_release
            assign shared_release_quotient=0;
            assign shared_release_modulus=0;
        end
        if(SHARED_ARITHMETIC) begin : shared_arithmetic
            if (ENABLE_GUITAR) begin : guitar_filters
            for(bank=0;bank<(VOICE_COUNT+FILTER_LANES-1)/FILTER_LANES;bank=bank+1) begin : filters
                localparam integer COUNT=VOICE_COUNT-bank*FILTER_LANES < FILTER_LANES ?
                    VOICE_COUNT-bank*FILTER_LANES : FILTER_LANES;
                guitar_body_tone_bank #(.LANES(COUNT)) u_body_bank(
                    .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
                    .note_on(voice_note_on[bank*FILTER_LANES+:COUNT]),
                    .string_waves(body_string_waves[bank*FILTER_LANES*16+:COUNT*16]),
                    .waves(body_waves[bank*FILTER_LANES*16+:COUNT*16])
                );
            end
            end else begin : no_guitar_filters
                assign body_waves=0;
            end
            for(bank=0;bank<(VOICE_COUNT+BODY_LANES-1)/BODY_LANES;bank=bank+1) begin : bodies
                localparam integer COUNT=VOICE_COUNT-bank*BODY_LANES < BODY_LANES ?
                    VOICE_COUNT-bank*BODY_LANES : BODY_LANES;
                bianzhong_ram_bank #(.LANES(COUNT),
                    .DYNAMIC_PITCH(ENABLE_EXPRESSION)) u_bell_bank(
                    .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
                    .note_on(bell_note_on[bank*BODY_LANES+:COUNT]),
                    .fcs(rendered_fc[bank*BODY_LANES*32+:COUNT*32]),
                    .velocities(voice_velocity[bank*BODY_LANES*8+:COUNT*8]),
                    .waves(bell_waves[bank*BODY_LANES*16+:COUNT*16])
                );
                wire [6:0] oscillator_cycle;
                wire signed [15:0] oscillator_lookup;
                wire signed [26:0] oscillator_product;
                oscillator_bank #(.LANES(COUNT)) u_oscillator_bank(
                    .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
                    .addresses(oscillator_addresses[bank*BODY_LANES*12+:COUNT*12]),
                    .operands(oscillator_operands[bank*BODY_LANES*18+:COUNT*18]),
                    .gains(oscillator_gains[bank*BODY_LANES*8+:COUNT*8]),
                    .cycle(oscillator_cycle),.lookup_wave(oscillator_lookup),
                    .product(oscillator_product)
                );
                for(v=0;v<COUNT;v=v+1) begin : oscillators
                    assign oscillator_cycles[(bank*BODY_LANES+v)*7+:7]=oscillator_cycle;
                    assign oscillator_lookups[(bank*BODY_LANES+v)*16+:16]=oscillator_lookup;
                    assign oscillator_products[(bank*BODY_LANES+v)*27+:27]=oscillator_product;
                end
            end
            for(bank=0;bank<(VOICE_COUNT+GAIN_LANES-1)/GAIN_LANES;bank=bank+1) begin : gains
                localparam integer COUNT=VOICE_COUNT-bank*GAIN_LANES < GAIN_LANES ?
                    VOICE_COUNT-bank*GAIN_LANES : GAIN_LANES;
                wire signed [44:0] product;
                voice_gain_bank #(.LANES(COUNT),.VELOCITY_START(70)) u_gain_bank(
                    .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
                    .operands_a(gain_operands_a[bank*GAIN_LANES*27+:COUNT*27]),
                    .operands_b(gain_operands_b[bank*GAIN_LANES*18+:COUNT*18]),
                    .steps(gain_steps[bank*GAIN_LANES*4+:COUNT*4]),.product(product)
                );
                for(v=0;v<COUNT;v=v+1) begin : products
                    assign gain_products[(bank*GAIN_LANES+v)*45+:45]=product;
                end
            end
        end else begin : private_arithmetic
            assign body_waves=0;
            assign bell_waves=0;
            assign oscillator_cycles=0;
            assign oscillator_lookups=0;
            assign oscillator_products=0;
            assign gain_steps=0;
            assign gain_products=0;
        end
        for (v = 0; v < VOICE_COUNT; v = v + 1) begin : voices
            assign bell_note_on[v]=voice_note_on[v] && voice_instrument[v*2+:2]==2;
            voice #(
                .ENABLE_TIMBRES(ENABLE_TIMBRES),
                .ENABLE_GUITAR(ENABLE_GUITAR),
                .DYNAMIC_PITCH(ENABLE_EXPRESSION),
                .EXTERNAL_PITCH(1),
                .SHARED_BODY(SHARED_ARITHMETIC),
                .SHARED_GAIN(SHARED_ARITHMETIC),
                .SHARED_BELL(SHARED_ARITHMETIC),
                .SHARED_OSCILLATOR(SHARED_ARITHMETIC),
                .SHARED_RELEASE(SHARED_ARITHMETIC),
                .OSCILLATOR_LANES(VOICE_COUNT-(v/BODY_LANES)*BODY_LANES < BODY_LANES ?
                    VOICE_COUNT-(v/BODY_LANES)*BODY_LANES : BODY_LANES),
                .OSCILLATOR_LANE(v%BODY_LANES),
                .ATTACK_SAMPLES(ATTACK_SAMPLES),
                .DECAY_SAMPLES(DECAY_SAMPLES),
                .SUSTAIN_LEVEL(SUSTAIN_LEVEL),
                .RELEASE_SAMPLES(RELEASE_SAMPLES)
            ) u_voice (
                .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
                .note_on(voice_note_on[v]), .note_off(voice_note_off[v]),
                .note_id(voice_note_id[v*7 +: 7]),
                .velocity(voice_velocity[v*8 +: 8]),
                .instrument(voice_instrument[v*2 +: 2]),
                .pitch_fc(rendered_fc[v*32 +: 32]),
                .pitch_period(rendered_period[v*48 +: 48]),
                .shared_release_quotient(shared_release_quotient),
                .shared_release_modulus(shared_release_modulus),
                .body_wave(body_waves[v*16+:16]),
                .bell_bank_wave(bell_waves[v*16+:16]),
                .oscillator_cycle(oscillator_cycles[v*7+:7]),
                .oscillator_lookup(oscillator_lookups[v*16+:16]),
                .oscillator_product(oscillator_products[v*27+:27]),
                .oscillator_address(oscillator_addresses[v*12+:12]),
                .oscillator_operand(oscillator_operands[v*18+:18]),
                .oscillator_gain(oscillator_gains[v*8+:8]),
                .body_string_wave(body_string_waves[v*16+:16]),
                .gain_step(gain_steps[v*4+:4]),
                .gain_product(gain_products[v*45+:45]),
                .gain_operand_a(gain_operands_a[v*27+:27]),
                .gain_operand_b(gain_operands_b[v*18+:18]),
                .audio(voice_samples[v*24 +: 24]), .active(voice_active[v]),
                .envelope_level(envelope_levels[v*16 +: 16]),
                .envelope_stage(envelope_stages[v*3 +: 3])
            );
        end

        if (A3_MODE) begin : serial_mix
            mixer_serial #(.VOICES(VOICE_COUNT)) u_mixer (
                .clk(clk), .rst_n(rst_n), .start(tick_sr[MIX_START]),
                .voice_samples(voice_samples), .volume(volume),
                .audio(mixed_audio), .overload_flag(mixed_overload)
            );
        end else begin : legacy_mix
            mixer #(.VOICES(VOICE_COUNT)) u_mixer (
                .voice_samples(voice_samples), .volume(volume),
                .audio(mixed_audio), .overload_flag(mixed_overload)
            );
        end

        always @(*) begin
            voice_count = 6'd0;
            for (i = 0; i < VOICE_COUNT; i = i + 1)
                voice_count = voice_count + voice_active[i];
        end
        assign active_voice_count = (!ev_overflow && !ev_fault) ? voice_count : 6'd0;

        // Hold each sample until the next valid pulse. Fault mute is immediate.
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                audio_left <= 24'sd0;
                audio_right <= 24'sd0;
                overload_flag <= 1'b0;
            end else if (!gate) begin
                audio_left <= 24'sd0;
                audio_right <= 24'sd0;
                overload_flag <= 1'b0;
            end else if (tick_sr[AUDIO_LATENCY-1]) begin
                audio_left <= mixed_audio;
                audio_right <= mixed_audio;
                overload_flag <= mixed_overload;
            end
        end
    end endgenerate

    assign event_overflow = ev_overflow;
    assign param_overflow = p_overflow;

    // Allocator updates at tick, voices react one clock later, ROM settles next.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_sr <= 3'd0;
            audio_core_valid <= 1'b0;
        end else begin
            tick_sr <= {tick_sr[AUDIO_LATENCY-2:0], sample_tick};
            audio_core_valid <= tick_sr[AUDIO_LATENCY-1];
        end
    end

endmodule

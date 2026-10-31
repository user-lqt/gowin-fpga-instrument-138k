//=============================================================================
// audio_core.v - Parameterized 32/64-voice engine; A1/A2 are regression modes.
//
//   事件输入(B) -> 音高查表 -> 振荡器 -> 力度/音量 -> 采样输出(C)
//
//   采样域:每个 sample_tick(48 kHz)更新一次音频状态。
//   正式64声部路径按组分时处理，延迟由 MIX_START 和 VOICE_COUNT 确定；
//   三拍流水线仅适用于单音回归配置，不能当作整机按键至DAC延迟。
//
//   每个声部保留独立音高、相位及包络；共享运算器不等于共享声部状态。
//   合规:全部样本由本模块逐样本实时计算,无任何预录 PCM。
//=============================================================================
`include "event_defs.vh"

module audio_core #(
    parameter integer ENABLE_POLYPHONY = 1,
    parameter integer VOICE_COUNT = 32,
    parameter integer ENABLE_STEAL = 1,
    parameter integer ENABLE_TIMBRES = 1,
    parameter integer SHARE_VOICE_ARITHMETIC = 1,
    parameter integer ENABLE_EXPRESSION = 0,
    parameter integer ENABLE_ACCEPTANCE = 0,
    parameter integer STEREO_OUTPUT = 0,
    parameter integer EVENT_DEPTH = 64,
    parameter integer RAM_BODY = 1,
    parameter integer ATTACK_SAMPLES = 480,
    parameter integer DECAY_SAMPLES = 2400,
    parameter [15:0] SUSTAIN_LEVEL = 16'd45875,
    parameter integer RELEASE_SAMPLES = 4800,
    parameter integer BELL_RING_SAMPLES = 192000,
    parameter integer ENABLE_GUITAR = 1,
    parameter integer RAM_GAIN_HAMMER = VOICE_COUNT>32,
    parameter integer DIRECT_STRING_STATE = VOICE_COUNT>32,
    parameter integer STRING_BANK_LANES = 8,
    parameter integer BANKED_GAIN_OUTPUT = VOICE_COUNT>32,
    parameter integer RAM_ALLOCATOR_AGE = VOICE_COUNT>32,
    parameter integer BANK_PIANO = VOICE_COUNT>32,
    parameter integer BANK_TIMBRE_GAIN = VOICE_COUNT>32,
    parameter integer BANKED_PITCH_RESULTS = VOICE_COUNT>32,
    parameter integer COMPACT_BODY = VOICE_COUNT>32,
    parameter integer RAM_PIANO_BODY = VOICE_COUNT>32,
    parameter integer BLOCK_STRING_STATE = VOICE_COUNT>32,
    parameter integer SYNC_ENVELOPE_STATE = VOICE_COUNT>32,
    parameter integer RAM_STRIKE_STATE = VOICE_COUNT>32,
    parameter integer PACK_STRING_STATE = VOICE_COUNT>32
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire               acceptance_mode,

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

    output wire [(VOICE_COUNT>32 ? 7 : 6)-1:0] active_voice_count,
    output wire               engine_ready,
    output reg                overload_flag,
    output wire               event_overflow,
    output wire               param_overflow
);

    //-------------------------------------------------------------------------
    // 上电就绪保护：复位后等待固定周期，再接受正常演奏输出。
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
    wire pure_tone=ENABLE_ACCEPTANCE && acceptance_mode;
    // Exact FFT-bin spacing, used only by the dedicated acceptance mode.
    function [31:0] acceptance_fc;
        input [6:0] note;
        begin acceptance_fc=(32'd257+(({25'd0,note}-32'd48)<<5))<<18;end
    endfunction

    // B/C must pace bursts to fit the finite input queues; no ready signal exists.
    localparam integer PARAM_DEPTH = 4;
    localparam integer EVENT_PTR_BITS = $clog2(EVENT_DEPTH);
    localparam [EVENT_PTR_BITS-1:0] LAST_EVENT_SLOT = EVENT_DEPTH-1;
    localparam [EVENT_PTR_BITS-1:0] EVENT_PTR_ONE = 1;
    localparam integer A3_MODE = ENABLE_POLYPHONY && ENABLE_TIMBRES;
    localparam integer SHARED_ARITHMETIC = A3_MODE && SHARE_VOICE_ARITHMETIC;
    localparam integer WIDE_POLYPHONY = VOICE_COUNT>32;
    localparam integer LOCAL_PITCH = BANKED_PITCH_RESULTS && VOICE_COUNT==64 &&
        SHARED_ARITHMETIC && ENABLE_EXPRESSION && STRING_BANK_LANES==8;
    localparam integer LOCAL_BODY = VOICE_COUNT==64 && SHARED_ARITHMETIC &&
        ENABLE_GUITAR && RAM_BODY && COMPACT_BODY && BANK_PIANO &&
        RAM_GAIN_HAMMER && BANK_TIMBRE_GAIN;
    localparam integer LOCAL_PIANO = VOICE_COUNT==64 && SHARED_ARITHMETIC &&
        RAM_PIANO_BODY && BANK_PIANO && RAM_GAIN_HAMMER && BANK_TIMBRE_GAIN;
    localparam integer LOCAL_STRIKE = VOICE_COUNT==64 && SHARED_ARITHMETIC &&
        RAM_STRIKE_STATE && BANK_PIANO && RAM_GAIN_HAMMER && BANK_TIMBRE_GAIN;
    localparam integer BANKED_MIX = WIDE_POLYPHONY && SHARED_ARITHMETIC &&
        BANKED_GAIN_OUTPUT;
    localparam integer GAIN_LANES = VOICE_COUNT < 8 ? VOICE_COUNT :
        WIDE_POLYPHONY ? 16 : 8;
    localparam integer GAIN_START = WIDE_POLYPHONY ? 134 :
        GAIN_LANES>4 ? 74-GAIN_LANES : 70;
    localparam integer BODY_LANES = VOICE_COUNT < 8 ? VOICE_COUNT :
        WIDE_POLYPHONY ? 16 : 8;
    // Body outputs use the preceding frame's filter state, so the filter
    // recurrence may finish after gain processing but before the next tick.
    localparam integer FILTER_LANES = VOICE_COUNT < 16 ? VOICE_COUNT : 16;
    localparam integer MIX_START = SHARED_ARITHMETIC ? WIDE_POLYPHONY ? 168 :
        69+(VOICE_COUNT<4 ? VOICE_COUNT : 4) : 14;
    localparam integer AUDIO_LATENCY = A3_MODE ? VOICE_COUNT + MIX_START + 4 : 3;
    localparam [15:0] DEFAULT_VOLUME = A3_MODE ? 16'h07ff :
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
    wire [EVENT_PTR_BITS:0] ev_count_plus =
        ev_count + {{EVENT_PTR_BITS{1'b0}},1'b1};
    wire [EVENT_PTR_BITS:0] ev_count_minus =
        ev_count - {{EVENT_PTR_BITS{1'b0}},1'b1};
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
                    ev_wr <= ev_wr == LAST_EVENT_SLOT ?
                        {EVENT_PTR_BITS{1'b0}} : ev_wr + EVENT_PTR_ONE;
                end
                if (ev_pop)
                    ev_rd <= ev_rd == LAST_EVENT_SLOT ?
                        {EVENT_PTR_BITS{1'b0}} : ev_rd + EVENT_PTR_ONE;
                case ({ev_push, ev_pop})
                    2'b10: ev_count <= ev_count_plus;
                    2'b01: ev_count <= ev_count_minus;
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
                    (selected_param_val==16'd2 ? 2'd2 : 2'd0) :
                    (selected_param_val > 16'd3 ? 2'd0 : selected_param_val[1:0]);
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
        wire [VOICE_COUNT*32-1:0] expression_fc;
        wire [VOICE_COUNT*48-1:0] rendered_period;
        wire [((VOICE_COUNT+15)/16)*20-1:0] pitch_read_slots;
        wire [((VOICE_COUNT+15)/16)*400-1:0] pitch_read_values;
        wire [((VOICE_COUNT+7)/8)*3-1:0] oscillator_pitch_lanes,string_pitch_lanes;
        wire [((VOICE_COUNT+15)/16)*4-1:0] bell_pitch_lanes;
        if(ENABLE_EXPRESSION && A3_MODE) begin : expression
            pitch_expression_bank #(.VOICES(VOICE_COUNT),.STATIC_BASE_PITCH(1),
                .DUAL_PITCH_PRODUCTS(WIDE_POLYPHONY),
                .MASK_RESULT_RESET(WIDE_POLYPHONY),
                .BANKED_RESULTS(LOCAL_PITCH),
                .BOUNDED_PERIOD(1),.SYNC_LOOKUP(1)) u_pitch(
                .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
                .param_valid(sample_tick && (p_pop || p_bypass)),
                .param_id(selected_param_id),.param_value(selected_param_val),
                .note_on(voice_note_on),.key_down(key_down),.notes(voice_note_id),
                .base_fcs(voice_fc),.base_periods(voice_period),
                .fcs(expression_fc),.periods(rendered_period),.busy(),
                .result_read_slots(pitch_read_slots),.result_read_values(pitch_read_values));
        end else begin : fixed_pitch
            assign expression_fc=voice_fc;
            assign rendered_period=voice_period;
            assign pitch_read_values=0;
        end
        wire [31:0] selected_fc;
        wire [47:0] selected_period;
        `include "note_functions.vh"
        assign selected_fc=pure_tone ? acceptance_fc(selected_note) : event_note_fc(selected_note);
        assign selected_period=event_note_period_q16(selected_note);
        // A 16-bit wave * 8-bit strike gain * 2 needs 25 signed bits.
        // Keep this headroom until master gain and final PCM24 saturation.
        localparam integer VOICE_SAMPLE_BITS=A3_MODE ? 25 : 24;
        wire [VOICE_COUNT*VOICE_SAMPLE_BITS-1:0] voice_samples;
        wire [VOICE_COUNT*16-1:0] body_string_waves,body_waves;
        wire [((VOICE_COUNT+15)/16)*4-1:0] body_read_lanes;
        wire [((VOICE_COUNT+15)/16)*16-1:0] body_read_waves;
        wire [VOICE_COUNT*34-1:0] gain_hammers;
        wire [VOICE_COUNT*16-1:0] gain_piano_bodies;
        wire [VOICE_COUNT*16-1:0] gain_raw_waves,gain_raw_noises,gain_raw_strikes;
        wire [VOICE_COUNT-1:0] gain_piano_mask;
        wire [VOICE_COUNT-1:0] gain_guitar_mask,gain_guitar_boost_mask;
        wire [((VOICE_COUNT+GAIN_LANES-1)/GAIN_LANES)*VOICE_SAMPLE_BITS-1:0] gain_bank_samples;
        wire [(VOICE_COUNT>1 ? $clog2(VOICE_COUNT) : 1)-1:0] mixer_sample_index;
        wire [VOICE_COUNT*16-1:0] bell_waves;
        wire [VOICE_COUNT*16-1:0] string_bank_waves;
        wire [VOICE_COUNT-1:0] string_enabled;
        wire [VOICE_COUNT*16-1:0] state_oscillator_waves;
        wire [VOICE_COUNT*8-1:0] oscillator_brightnesses;
        wire [VOICE_COUNT*2-1:0] oscillator_instruments;
        wire [VOICE_COUNT-1:0] bell_note_on;
        wire [VOICE_COUNT*12-1:0] oscillator_addresses;
        wire [VOICE_COUNT*18-1:0] oscillator_operands;
        wire [VOICE_COUNT*8-1:0] oscillator_gains;
        wire [VOICE_COUNT*7-1:0] oscillator_cycles;
        wire [VOICE_COUNT*16-1:0] oscillator_lookups;
        wire [VOICE_COUNT*27-1:0] oscillator_products;
        wire [VOICE_COUNT*32-1:0] oscillator_phase_increments;
        wire [VOICE_COUNT*32-1:0] oscillator_phase_operands;
        wire [VOICE_COUNT*32-1:0] oscillator_updated_phases;
        wire [VOICE_COUNT*26-1:0] oscillator_upper_operands;
        wire [VOICE_COUNT*26-1:0] oscillator_updated_uppers;
        wire [VOICE_COUNT*27-1:0] gain_operands_a;
        wire [VOICE_COUNT*18-1:0] gain_operands_b;
        wire [VOICE_COUNT*4-1:0] gain_steps;
        wire [VOICE_COUNT*45-1:0] gain_products;
        wire [VOICE_COUNT*16-1:0] envelope_levels;
        wire [VOICE_COUNT*3-1:0] envelope_stages;
        wire [VOICE_COUNT*16-1:0] bank_envelope_levels;
        wire [VOICE_COUNT*3-1:0] bank_envelope_stages;
        wire [VOICE_COUNT-1:0] bank_envelope_active;
        wire [15:0] shared_release_quotient,shared_release_modulus;
        wire full_pulse;
        wire signed [23:0] mixed_audio;
        wire signed [23:0] mixed_right;
        wire mixed_right_overload;
        wire mixed_overload;
        wire gate = ready_r && !ev_overflow && !ev_fault;
        reg [(VOICE_COUNT>32 ? 7 : 6)-1:0] voice_count;
        integer i;

        voice_allocator #(
            .VOICES(VOICE_COUNT),
            .STEAL_ON_FULL(ENABLE_STEAL),
            .SHARED_AGE(SHARED_ARITHMETIC),
            .SERIAL_RANK(SHARED_ARITHMETIC),
            .RAM_AGE(RAM_ALLOCATOR_AGE),
            .LOCAL_ALLOCATE(WIDE_POLYPHONY),
            .BROADCAST_BASE_PITCH(ENABLE_EXPRESSION && A3_MODE)
        ) u_allocator (
            .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
            .event_valid(ev_pop || ev_bypass),
            .event_type(selected_type), .note_id(selected_note),
            .velocity(selected_vel), .voice_active(voice_active),
            .instrument(pure_tone ? 2'd2 : instrument),
            .note_fc(selected_fc),.note_period(selected_period),
            .envelope_levels(envelope_levels),
            .voice_note_on(voice_note_on), .voice_note_off(voice_note_off),
            .key_down(key_down), .voice_note_id(voice_note_id),
            .voice_velocity(voice_velocity), .voice_instrument(voice_instrument),
            .voice_fc(voice_fc),.voice_period(voice_period),
            .full_pulse(full_pulse)
        );

        genvar v,bank;
        if(LOCAL_PITCH) begin : local_pitch_reads
            for(bank=0;bank<4;bank=bank+1) begin : banks
                assign pitch_read_slots[bank*20+:20]={
                    bell_pitch_lanes[bank*4+:4],
                    1'b1,string_pitch_lanes[(bank*2+1)*3+:3],
                    1'b0,string_pitch_lanes[bank*2*3+:3],
                    1'b1,oscillator_pitch_lanes[(bank*2+1)*3+:3],
                    1'b0,oscillator_pitch_lanes[bank*2*3+:3]};
            end
        end else begin : parallel_pitch_reads
            assign pitch_read_slots=0;
        end
        if(WIDE_POLYPHONY && SHARED_ARITHMETIC) begin : state_oscillators
            for(bank=0;bank<(VOICE_COUNT+7)/8;bank=bank+1) begin : banks
                localparam integer COUNT=VOICE_COUNT-bank*8<8 ? VOICE_COUNT-bank*8 : 8;
                wire [(COUNT>1 ? $clog2(COUNT) : 1)-1:0] pitch_lane;
                wire [31:0] local_fc;
                if(LOCAL_PITCH) begin : pitch_reader
                    assign oscillator_pitch_lanes[bank*3+:3]=pitch_lane;
                    assign local_fc=pure_tone ?
                        acceptance_fc(voice_note_id[(bank*8+pitch_lane)*7+:7]) :
                        pitch_read_values[((bank/2)*5+bank%2)*80+:32];
                end else assign local_fc=0;
                oscillator_state_bank #(.LANES(COUNT),.ENABLE_ACCEPTANCE(ENABLE_ACCEPTANCE),
                    .EXTERNAL_PITCH_SELECT(LOCAL_PITCH)) u_oscillators(
                    .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.acceptance_mode(pure_tone),
                    .note_on(voice_note_on[bank*8+:COUNT]),
                    .fcs(rendered_fc[bank*8*32+:COUNT*32]),
                    .instruments(oscillator_instruments[bank*8*2+:COUNT*2]),
                    .brightnesses(oscillator_brightnesses[bank*8*8+:COUNT*8]),
                    .waves(state_oscillator_waves[bank*8*16+:COUNT*16]),
                    .selected_fc(local_fc),.pitch_lane(pitch_lane));
            end
        end else begin : original_oscillators
            assign state_oscillator_waves=0;
        end
        if(WIDE_POLYPHONY && SHARED_ARITHMETIC && ENABLE_GUITAR) begin : string_banks
            for(bank=0;bank<(VOICE_COUNT+STRING_BANK_LANES-1)/STRING_BANK_LANES;bank=bank+1) begin : banks
                localparam integer BASE=bank*STRING_BANK_LANES;
                localparam integer COUNT=VOICE_COUNT-BASE<STRING_BANK_LANES ?
                    VOICE_COUNT-BASE : STRING_BANK_LANES;
                wire [(COUNT>1 ? $clog2(COUNT) : 1)-1:0] pitch_lane;
                wire [79:0] local_pitch;
                if(LOCAL_PITCH) begin : pitch_reader
                    assign string_pitch_lanes[bank*3+:3]=pitch_lane;
                    assign local_pitch=pitch_read_values[((bank/2)*5+2+bank%2)*80+:80];
                end else assign local_pitch=0;
                plucked_string_bank #(.LANES(COUNT),
                    .BLOCK_STATE(BLOCK_STRING_STATE),
                    .DYNAMIC_PITCH(ENABLE_EXPRESSION),
                    .EXTERNAL_PITCH_SELECT(LOCAL_PITCH),
                    .PACKED_STATE(PACK_STRING_STATE),
                    .DIRECT_STATE_READ(DIRECT_STRING_STATE)) u_strings(
                    .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
                    .note_on(voice_note_on[BASE+:COUNT]),
                    .enabled(string_enabled[BASE+:COUNT]),
                    .fcs(rendered_fc[BASE*32+:COUNT*32]),
                    .periods(rendered_period[BASE*48+:COUNT*48]),
                    .velocities(voice_velocity[BASE*8+:COUNT*8]),
                    .waves(string_bank_waves[BASE*16+:COUNT*16]),
                    .pitch_fc(local_pitch[31:0]),.pitch_period(local_pitch[79:32]),
                    .pitch_lane(pitch_lane));
            end
        end else begin : private_strings
            assign string_bank_waves=0;
            assign string_pitch_lanes=0;
        end
        if(SHARED_ARITHMETIC) begin : release_division
            adsr_state_bank #(.VOICES(VOICE_COUNT),.ENABLE_ACCEPTANCE(ENABLE_ACCEPTANCE),
                .SYNC_STATE(SYNC_ENVELOPE_STATE),
                .RELEASE_SAMPLES(RELEASE_SAMPLES),
                .BELL_RING_SAMPLES(BELL_RING_SAMPLES)) u_bank(
                .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.acceptance_mode(pure_tone),
                .note_on(voice_note_on),.note_off(voice_note_off),
                .instruments(voice_instrument),.velocities(voice_velocity),
                .levels(bank_envelope_levels),.stages(bank_envelope_stages),
                .active(bank_envelope_active));
            assign shared_release_quotient=0;
            assign shared_release_modulus=0;
        end else begin : private_release
            assign shared_release_quotient=0;
            assign shared_release_modulus=0;
            assign bank_envelope_levels=0;
            assign bank_envelope_stages=0;
            assign bank_envelope_active=0;
        end
        if(SHARED_ARITHMETIC) begin : shared_arithmetic
            if(ENABLE_GUITAR) begin : guitar_filters
            for(bank=0;bank<(VOICE_COUNT+FILTER_LANES-1)/FILTER_LANES;bank=bank+1) begin : filters
                localparam integer COUNT=VOICE_COUNT-bank*FILTER_LANES < FILTER_LANES ?
                    VOICE_COUNT-bank*FILTER_LANES : FILTER_LANES;
                if(RAM_BODY) begin : ram_body
                    wire [(COUNT>1 ? $clog2(COUNT) : 1)-1:0] read_lane;
                    wire signed [15:0] read_wave;
                    if(LOCAL_BODY) begin : local_reader
                        assign read_lane=body_read_lanes[bank*4+:4];
                        assign body_read_waves[bank*16+:16]=read_wave;
                    end else assign read_lane=0;
                    guitar_body_ram_bank #(.LANES(COUNT),
                        .COMPACT_STATE(COMPACT_BODY),
                        .PARALLEL_OUTPUT(!LOCAL_BODY)) u_body_bank(
                        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
                        .note_on(voice_note_on[bank*FILTER_LANES+:COUNT]),
                        .string_waves(body_string_waves[bank*FILTER_LANES*16+:COUNT*16]),
                        .waves(body_waves[bank*FILTER_LANES*16+:COUNT*16]),
                        .output_lane(read_lane),
                        .selected_wave(read_wave)
                    );
                end else begin : register_body
                    guitar_body_tone_bank #(.LANES(COUNT)) u_body_bank(
                        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
                        .note_on(voice_note_on[bank*FILTER_LANES+:COUNT]),
                        .string_waves(body_string_waves[bank*FILTER_LANES*16+:COUNT*16]),
                        .waves(body_waves[bank*FILTER_LANES*16+:COUNT*16])
                    );
                end
            end
            end else begin : no_guitar_filters
                assign body_waves=0;
            end
            for(bank=0;bank<(VOICE_COUNT+BODY_LANES-1)/BODY_LANES;bank=bank+1) begin : bodies
                localparam integer COUNT=VOICE_COUNT-bank*BODY_LANES < BODY_LANES ?
                    VOICE_COUNT-bank*BODY_LANES : BODY_LANES;
                wire [(COUNT>1 ? $clog2(COUNT) : 1)-1:0] pitch_lane;
                wire [31:0] local_fc;
                if(LOCAL_PITCH) begin : pitch_reader
                    assign bell_pitch_lanes[bank*4+:4]=pitch_lane;
                    assign local_fc=pitch_read_values[(bank*5+4)*80+:32];
                end else assign local_fc=0;
                bianzhong_ram_bank #(.LANES(COUNT),
                    .EXTERNAL_PITCH_SELECT(LOCAL_PITCH),
                    .DYNAMIC_PITCH(ENABLE_EXPRESSION)) u_bell_bank(
                    .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
                    .note_on(bell_note_on[bank*BODY_LANES+:COUNT]),
                    .velocities(voice_velocity[bank*BODY_LANES*8+:COUNT*8]),
                    .fcs(rendered_fc[bank*BODY_LANES*32+:COUNT*32]),
                    .waves(bell_waves[bank*BODY_LANES*16+:COUNT*16]),
                    .selected_fc(local_fc),.pitch_lane(pitch_lane)
                );
                wire [6:0] oscillator_cycle;
                wire signed [15:0] oscillator_lookup;
                wire signed [26:0] oscillator_product;
                wire [31:0] oscillator_phase_increment;
                wire [31:0] oscillator_updated_phase;
                wire signed [25:0] oscillator_updated_upper;
                if(!WIDE_POLYPHONY) begin : original_bank
                oscillator_bank #(.LANES(COUNT),.SHARED_STRETCH(1),
                    .SHARED_COEFFICIENTS(1),.SHARED_PHASE_ADD(1),
                    .SHARED_UPPER_ADD(1)) u_oscillator_bank(
                    .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
                    .addresses(oscillator_addresses[bank*BODY_LANES*12+:COUNT*12]),
                    .operands(oscillator_operands[bank*BODY_LANES*18+:COUNT*18]),
                    .gains(oscillator_gains[bank*BODY_LANES*8+:COUNT*8]),
                    .fcs(rendered_fc[bank*BODY_LANES*32+:COUNT*32]),
                    .phase_operands(oscillator_phase_operands[bank*BODY_LANES*32+:COUNT*32]),
                    .upper_operands(oscillator_upper_operands[bank*BODY_LANES*26+:COUNT*26]),
                    .cycle(oscillator_cycle),.lookup_wave(oscillator_lookup),
                    .product(oscillator_product),.phase_increment(oscillator_phase_increment),
                    .updated_phase(oscillator_updated_phase),
                    .updated_upper(oscillator_updated_upper)
                );
                end else begin : unused_bank
                    assign oscillator_cycle=0;
                    assign oscillator_lookup=0;
                    assign oscillator_product=0;
                    assign oscillator_phase_increment=0;
                    assign oscillator_updated_phase=0;
                    assign oscillator_updated_upper=0;
                end
                for(v=0;v<COUNT;v=v+1) begin : oscillators
                    assign oscillator_cycles[(bank*BODY_LANES+v)*7+:7]=oscillator_cycle;
                    assign oscillator_lookups[(bank*BODY_LANES+v)*16+:16]=oscillator_lookup;
                    assign oscillator_products[(bank*BODY_LANES+v)*27+:27]=oscillator_product;
                    assign oscillator_phase_increments[(bank*BODY_LANES+v)*32+:32]=oscillator_phase_increment;
                    assign oscillator_updated_phases[(bank*BODY_LANES+v)*32+:32]=oscillator_updated_phase;
                    assign oscillator_updated_uppers[(bank*BODY_LANES+v)*26+:26]=oscillator_updated_upper;
                end
            end
            for(bank=0;bank<(VOICE_COUNT+GAIN_LANES-1)/GAIN_LANES;bank=bank+1) begin : gains
                localparam integer COUNT=VOICE_COUNT-bank*GAIN_LANES < GAIN_LANES ?
                    VOICE_COUNT-bank*GAIN_LANES : GAIN_LANES;
                wire signed [44:0] product;
                wire signed [33:0] hammer;
                wire [(COUNT>1 ? $clog2(COUNT) : 1)-1:0] body_lane;
                wire signed [15:0] body_wave;
                wire signed [15:0] piano_body_wave;
                if(LOCAL_PIANO) begin : local_piano_state
                    piano_body_state_bank #(.LANES(COUNT)) u_piano_body(
                        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
                        .note_on(voice_note_on[bank*GAIN_LANES+:COUNT]),
                        .piano_active(gain_piano_mask[bank*GAIN_LANES+:COUNT] &
                            voice_active[bank*GAIN_LANES+:COUNT]),
                        .waves(state_oscillator_waves[bank*GAIN_LANES*16+:COUNT*16]),
                        .read_lane(body_lane),.selected_body(piano_body_wave));
                end else assign piano_body_wave=0;
                if(LOCAL_BODY) begin : local_body_reader
                    assign body_read_lanes[bank*4+:4]=body_lane;
                    assign body_wave=body_read_waves[bank*16+:16];
                end else assign body_wave=0;
                voice_gain_bank #(.LANES(COUNT),.VELOCITY_START(GAIN_START),
                    .OUTPUT_BITS(VOICE_SAMPLE_BITS),
                    .LOCAL_SELECT(WIDE_POLYPHONY),.RAM_VELOCITY(WIDE_POLYPHONY),
                    .RAM_HAMMER(WIDE_POLYPHONY && RAM_GAIN_HAMMER),
                    .RAM_OUTPUT(BANKED_MIX),
                    .BANK_PIANO(WIDE_POLYPHONY && BANK_PIANO && RAM_GAIN_HAMMER),
                    .BANK_TIMBRE_GAIN(WIDE_POLYPHONY && BANK_PIANO &&
                        RAM_GAIN_HAMMER && BANK_TIMBRE_GAIN),
                    .LOCAL_BODY(LOCAL_BODY),
                    .LOCAL_PIANO(LOCAL_PIANO),
                    .LOCAL_STRIKE(LOCAL_STRIKE),
                    .DIRECT_INPUTS(WIDE_POLYPHONY && BANK_PIANO &&
                        RAM_GAIN_HAMMER && BANK_TIMBRE_GAIN)) u_gain_bank(
                    .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
                    .operands_a(gain_operands_a[bank*GAIN_LANES*27+:COUNT*27]),
                    .operands_b(gain_operands_b[bank*GAIN_LANES*18+:COUNT*18]),
                    .steps(gain_steps[bank*GAIN_LANES*4+:COUNT*4]),.product(product),
                    .hammer(hammer),
                    .piano_bodies(gain_piano_bodies[bank*GAIN_LANES*16+:COUNT*16]),
                    .piano_mask(gain_piano_mask[bank*GAIN_LANES+:COUNT]),
                    .guitar_mask(gain_guitar_mask[bank*GAIN_LANES+:COUNT]),
                    .guitar_boost_mask(gain_guitar_boost_mask[bank*GAIN_LANES+:COUNT]),
                    .raw_waves(gain_raw_waves[bank*GAIN_LANES*16+:COUNT*16]),
                    .raw_noises(gain_raw_noises[bank*GAIN_LANES*16+:COUNT*16]),
                    .raw_strikes(gain_raw_strikes[bank*GAIN_LANES*16+:COUNT*16]),
                    .raw_velocities(voice_velocity[bank*GAIN_LANES*8+:COUNT*8]),
                    .raw_envelopes(envelope_levels[bank*GAIN_LANES*16+:COUNT*16]),
                    .selected_body_wave(body_wave),
                    .selected_piano_body(piano_body_wave),
                    .note_on(voice_note_on[bank*GAIN_LANES+:COUNT]),
                    .input_lane(body_lane),
                    .output_index(mixer_sample_index[(COUNT>1 ? $clog2(COUNT) : 1)-1:0]),
                    .output_sample(gain_bank_samples[bank*VOICE_SAMPLE_BITS+:VOICE_SAMPLE_BITS])
                );
                for(v=0;v<COUNT;v=v+1) begin : products
                    assign gain_products[(bank*GAIN_LANES+v)*45+:45]=product;
                    assign gain_hammers[(bank*GAIN_LANES+v)*34+:34]=
                        WIDE_POLYPHONY && BANK_PIANO && RAM_GAIN_HAMMER ? 34'd0 : hammer;
                end
            end
        end else begin : private_arithmetic
            assign gain_hammers=0;
            assign gain_bank_samples=0;
            assign body_waves=0;
            assign bell_waves=0;
            assign oscillator_cycles=0;
            assign oscillator_lookups=0;
            assign oscillator_products=0;
            assign oscillator_phase_increments=0;
            assign oscillator_updated_phases=0;
            assign oscillator_updated_uppers=0;
            assign gain_steps=0;
            assign gain_products=0;
        end
        for (v = 0; v < VOICE_COUNT; v = v + 1) begin : voices
            assign rendered_fc[v*32+:32]=pure_tone ?
                acceptance_fc(voice_note_id[v*7+:7]) : expression_fc[v*32+:32];
            assign gain_piano_mask[v]=!pure_tone && voice_instrument[v*2+:2]==0;
            assign gain_guitar_mask[v]=!pure_tone && (voice_instrument[v*2+:2]==1 ||
                voice_instrument[v*2+:2]==3);
            assign gain_guitar_boost_mask[v]=ENABLE_GUITAR &&
                gain_guitar_mask[v] && voice_note_id[v*7+:7]>=24;
            assign bell_note_on[v]=!pure_tone && voice_note_on[v] && voice_instrument[v*2+:2]==2;
            assign string_enabled[v]=!pure_tone && (voice_instrument[v*2+:2]==1 ||
                voice_instrument[v*2+:2]==3) && voice_note_id[v*7+:7]>=24;
            assign oscillator_instruments[v*2+:2]=voice_instrument[v*2+:2]==1 ?
                2'd3 : voice_instrument[v*2+:2];
            voice #(
                .ENABLE_ACCEPTANCE(ENABLE_ACCEPTANCE),
                .OUTPUT_BITS(VOICE_SAMPLE_BITS),
                .ENABLE_TIMBRES(ENABLE_TIMBRES),
                .ENABLE_GUITAR(ENABLE_GUITAR),
                .DYNAMIC_PITCH(ENABLE_EXPRESSION),
                .EXTERNAL_PITCH(1),
                .SHARED_BODY(SHARED_ARITHMETIC),
                .SHARED_GAIN(SHARED_ARITHMETIC),
                .SHARED_BELL(SHARED_ARITHMETIC),
                .SHARED_OSCILLATOR(SHARED_ARITHMETIC),
                .SHARED_STRETCH(SHARED_ARITHMETIC),
                .SHARED_COEFFICIENTS(SHARED_ARITHMETIC),
                .SHARED_PHASE_ADD(SHARED_ARITHMETIC),
                .SHARED_UPPER_ADD(SHARED_ARITHMETIC),
                .SHARED_RELEASE(SHARED_ARITHMETIC),
                .SHARED_ENVELOPE(SHARED_ARITHMETIC),
                .SHARED_STRING(WIDE_POLYPHONY && SHARED_ARITHMETIC),
                  .SHARED_STATE_OSCILLATOR(WIDE_POLYPHONY && SHARED_ARITHMETIC),
                  .SHARED_GAIN_VELOCITY(WIDE_POLYPHONY && SHARED_ARITHMETIC),
                  .SHARED_GAIN_HAMMER(WIDE_POLYPHONY && SHARED_ARITHMETIC && RAM_GAIN_HAMMER),
                  .SHARED_GAIN_OUTPUT(BANKED_MIX),
                  .BANK_PIANO(WIDE_POLYPHONY && SHARED_ARITHMETIC &&
                      BANK_PIANO && RAM_GAIN_HAMMER),
                  .BANK_TIMBRE_GAIN(WIDE_POLYPHONY && SHARED_ARITHMETIC &&
                      BANK_PIANO && RAM_GAIN_HAMMER && BANK_TIMBRE_GAIN),
                  .LOCAL_BODY_OUTPUT(LOCAL_BODY),
                  .LOCAL_PIANO_STATE(LOCAL_PIANO),
                  .LOCAL_STRIKE_STATE(LOCAL_STRIKE),
                .OSCILLATOR_LANES(VOICE_COUNT-(v/BODY_LANES)*BODY_LANES < BODY_LANES ?
                    VOICE_COUNT-(v/BODY_LANES)*BODY_LANES : BODY_LANES),
                .OSCILLATOR_LANE(v%BODY_LANES),
                .ATTACK_SAMPLES(ATTACK_SAMPLES),
                .DECAY_SAMPLES(DECAY_SAMPLES),
                .SUSTAIN_LEVEL(SUSTAIN_LEVEL),
                .RELEASE_SAMPLES(RELEASE_SAMPLES),
                .BELL_RING_SAMPLES(BELL_RING_SAMPLES)
            ) u_voice (
                .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),.acceptance_mode(pure_tone),
                .note_on(voice_note_on[v]), .note_off(voice_note_off[v]),
                .note_id(voice_note_id[v*7 +: 7]),
                .velocity(voice_velocity[v*8 +: 8]),
                .instrument(voice_instrument[v*2 +: 2]),
                .pitch_fc(rendered_fc[v*32 +: 32]),
                .pitch_period(rendered_period[v*48 +: 48]),
                .shared_release_quotient(shared_release_quotient),
                .shared_release_modulus(shared_release_modulus),
                .bank_envelope_level(bank_envelope_levels[v*16+:16]),
                .bank_envelope_stage(bank_envelope_stages[v*3+:3]),
                .bank_envelope_active(bank_envelope_active[v]),
                .body_wave(body_waves[v*16+:16]),
                .string_bank_wave(string_bank_waves[v*16+:16]),
                .oscillator_bank_wave(state_oscillator_waves[v*16+:16]),
                .oscillator_brightness(oscillator_brightnesses[v*8+:8]),
                .bell_bank_wave(bell_waves[v*16+:16]),
                .oscillator_cycle(oscillator_cycles[v*7+:7]),
                .oscillator_lookup(oscillator_lookups[v*16+:16]),
                .oscillator_product(oscillator_products[v*27+:27]),
                .oscillator_phase_increment(oscillator_phase_increments[v*32+:32]),
                .oscillator_updated_phase(oscillator_updated_phases[v*32+:32]),
                .oscillator_phase_operand(oscillator_phase_operands[v*32+:32]),
                .oscillator_updated_upper(oscillator_updated_uppers[v*26+:26]),
                .oscillator_upper_operand(oscillator_upper_operands[v*26+:26]),
                .oscillator_address(oscillator_addresses[v*12+:12]),
                .oscillator_operand(oscillator_operands[v*18+:18]),
                .oscillator_gain(oscillator_gains[v*8+:8]),
                .body_string_wave(body_string_waves[v*16+:16]),
                .gain_step(gain_steps[v*4+:4]),
                .gain_product(gain_products[v*45+:45]),
                .gain_operand_a(gain_operands_a[v*27+:27]),
                .gain_piano_body(gain_piano_bodies[v*16+:16]),
                .gain_raw_wave(gain_raw_waves[v*16+:16]),
                .gain_raw_noise(gain_raw_noises[v*16+:16]),
                .gain_raw_strike(gain_raw_strikes[v*16+:16]),
                  .gain_operand_b(gain_operands_b[v*18+:18]),
                  .gain_hammer(gain_hammers[v*34+:34]),
                .audio(voice_samples[v*VOICE_SAMPLE_BITS +: VOICE_SAMPLE_BITS]), .active(voice_active[v]),
                .envelope_level(envelope_levels[v*16 +: 16]),
                .envelope_stage(envelope_stages[v*3 +: 3])
            );
        end

        // PCM25 voice headroom is retained until the serial mixer's master
        // scaling and final PCM24 saturation; do not narrow individual voices.
        if (A3_MODE) begin : serial_mix
            mixer_serial #(.VOICES(VOICE_COUNT),.BANKED_INPUT(BANKED_MIX),
                .SAMPLE_BITS(VOICE_SAMPLE_BITS),
                .BANK_LANES(GAIN_LANES),.STEREO_OUTPUT(STEREO_OUTPUT)) u_mixer (
                .clk(clk), .rst_n(rst_n), .start(tick_sr[MIX_START]),
                .voice_samples(voice_samples), .volume(volume),
                .audio(mixed_audio), .overload_flag(mixed_overload),
                .bank_samples(gain_bank_samples),.voice_active(voice_active),
                .sample_index(mixer_sample_index),.stereo_center(pure_tone),
                .voice_notes(voice_note_id),.audio_right(mixed_right),
                .overload_right(mixed_right_overload)
            );
        end else begin : legacy_mix
            assign mixed_right=mixed_audio;
            assign mixed_right_overload=mixed_overload;
            assign mixer_sample_index=0;
            mixer #(.VOICES(VOICE_COUNT),.SAMPLE_BITS(VOICE_SAMPLE_BITS)) u_mixer (
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
                audio_right <= mixed_right;
                overload_flag <= mixed_overload | mixed_right_overload;
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

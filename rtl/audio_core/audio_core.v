//=============================================================================
// audio_core.v —— 音频核心顶层(A2:四声部, A1回归可选)
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
    localparam integer EVENT_DEPTH = 16;
    localparam integer PARAM_DEPTH = 4;

    reg [1:0]  ev_type_q [0:EVENT_DEPTH-1];
    reg [6:0]  ev_note_q [0:EVENT_DEPTH-1];
    reg [7:0]  ev_vel_q  [0:EVENT_DEPTH-1];
    reg [3:0]  ev_rd;
    reg [3:0]  ev_wr;
    reg [4:0]  ev_count;
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
    reg [1:0] instrument;

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
            volume       <= 16'hffff;
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
                    ev_wr <= ev_wr + 4'd1;
                end
                if (ev_pop)
                    ev_rd <= ev_rd + 4'd1;
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
                selected_param_id == `PARAM_VOLUME)
                volume <= selected_param_val;
            if (sample_tick && (p_pop || p_bypass) &&
                selected_param_id == `PARAM_INSTRUMENT &&
                selected_param_val < 16'd3)
                instrument <= selected_param_val[1:0];
        end
    end

    //-------------------------------------------------------------------------
    // 振荡器链:note -> fc -> 相位累加 -> 波表
    //-------------------------------------------------------------------------
    reg [2:0] tick_sr;
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
        .instrument  (instrument),
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
        wire [3:0] voice_active;
        wire [3:0] voice_note_on;
        wire [3:0] voice_note_off;
        wire [3:0] key_down;
        wire [27:0] voice_note_id;
        wire [31:0] voice_velocity;
        wire [95:0] voice_samples;
        wire [63:0] envelope_levels;
        wire [11:0] envelope_stages;
        wire full_pulse;
        wire signed [23:0] mixed_audio;
        wire mixed_overload;
        wire gate = ready_r && !ev_overflow && !ev_fault;
        reg [5:0] voice_count;
        integer i;

        voice_allocator #(.VOICES(4)) u_allocator (
            .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
            .event_valid(ev_pop || ev_bypass),
            .event_type(selected_type), .note_id(selected_note),
            .velocity(selected_vel), .voice_active(voice_active),
            .voice_note_on(voice_note_on), .voice_note_off(voice_note_off),
            .key_down(key_down), .voice_note_id(voice_note_id),
            .voice_velocity(voice_velocity), .full_pulse(full_pulse)
        );

        genvar v;
        for (v = 0; v < 4; v = v + 1) begin : voices
            voice #(
                .ATTACK_SAMPLES(ATTACK_SAMPLES),
                .DECAY_SAMPLES(DECAY_SAMPLES),
                .SUSTAIN_LEVEL(SUSTAIN_LEVEL),
                .RELEASE_SAMPLES(RELEASE_SAMPLES)
            ) u_voice (
                .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
                .note_on(voice_note_on[v]), .note_off(voice_note_off[v]),
                .note_id(voice_note_id[v*7 +: 7]),
                .velocity(voice_velocity[v*8 +: 8]),
                .instrument(instrument),
                .audio(voice_samples[v*24 +: 24]), .active(voice_active[v]),
                .envelope_level(envelope_levels[v*16 +: 16]),
                .envelope_stage(envelope_stages[v*3 +: 3])
            );
        end

        mixer u_mixer (
            .voice_samples(voice_samples), .volume(volume),
            .audio(mixed_audio), .overload_flag(mixed_overload)
        );

        always @(*) begin
            voice_count = 6'd0;
            for (i = 0; i < 4; i = i + 1)
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
            end else if (tick_sr[2]) begin
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
            tick_sr <= {tick_sr[1:0], sample_tick};
            audio_core_valid <= tick_sr[2];
        end
    end

endmodule

//=============================================================================
// audio_core.v —— 音频核心顶层(A1:单音实时合成)
//
//   事件输入(B) -> 音高查表 -> 振荡器 -> 力度/音量 -> 采样输出(C)
//
//   采样域:每个 sample_tick(48 kHz)更新一次音频状态。
//   流水线:phase(1 拍) -> ROM(1 拍) -> 输出寄存器(1 拍),共 3 拍固定延迟,
//           与音高无关,不影响相位连续性。
//
//   A1 范围:单一振荡器;ADSR / 复音 / 混音在 A2 引入。
//   合规:全部样本由本模块逐样本实时计算,无任何预录 PCM。
//=============================================================================
`include "event_defs.vh"

module audio_core (
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
    output reg                overload_flag
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

    //-------------------------------------------------------------------------
    // 事件捕获:先用 pending 锁存,再在下一个 sample_tick 消费
    //   —— 这样不要求 B 的事件脉冲与 sample_tick 对齐,也不会丢事件。
    //      (冻结卡:B 内部排队;A 每个 sample_tick 至少吸收 1 个事件)
    //-------------------------------------------------------------------------
    reg        ev_pending;
    reg [1:0]  ev_type_q;
    reg [6:0]  ev_note_q;
    reg [7:0]  ev_vel_q;

    reg        p_pending;
    reg [3:0]  p_id_q;
    reg [15:0] p_val_q;

    reg [6:0]  cur_note;
    reg [7:0]  cur_vel;
    reg        note_active;
    reg [15:0] volume;

    reg        phase_load_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ev_pending   <= 1'b0;
            ev_type_q    <= 2'd0;
            ev_note_q    <= 7'd0;
            ev_vel_q     <= 8'd0;
            p_pending    <= 1'b0;
            p_id_q       <= 4'd0;
            p_val_q      <= 16'd0;
            cur_note     <= 7'd0;
            cur_vel      <= 8'd0;
            note_active  <= 1'b0;
            volume       <= 16'hFFFF;
            phase_load_r <= 1'b0;
        end else begin
            phase_load_r <= 1'b0;

            // (1) 捕获脉冲(与 sample_tick 对齐与否都锁住)
            if (event_valid) begin
                ev_pending <= 1'b1;
                ev_type_q  <= event_type;
                ev_note_q  <= note_id;
                ev_vel_q   <= velocity;
            end
            if (param_valid) begin
                p_pending <= 1'b1;
                p_id_q    <= param_id;
                p_val_q   <= param_value;
            end

            // (2) 在 sample_tick 消费
            if (sample_tick) begin
                if (ev_pending) begin
                    ev_pending <= 1'b0;
                    case (ev_type_q)
                        `EVENT_NOTE_ON: begin
                            if (ev_vel_q != 8'd0) begin      // 力度 0 视为无效
                                cur_note     <= ev_note_q;
                                cur_vel      <= ev_vel_q;
                                note_active  <= 1'b1;
                                phase_load_r <= 1'b1;        // 固定起音相位
                            end
                        end
                        `EVENT_NOTE_OFF: begin
                            if (ev_note_q == cur_note)
                                note_active <= 1'b0;
                        end
                        default: ;                        // 参数另走 param 通路
                    endcase
                end

                if (p_pending) begin
                    p_pending <= 1'b0;
                    if (p_id_q == `PARAM_VOLUME)
                        volume <= p_val_q;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // 振荡器链:note -> fc -> 相位累加 -> 波表
    //-------------------------------------------------------------------------
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

    wire gate = ready_r & note_active;

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
    reg [2:0] tick_sr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tick_sr <= 3'd0;
        else        tick_sr <= {tick_sr[1:0], sample_tick};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) audio_core_valid <= 1'b0;
        else        audio_core_valid <= tick_sr[2];
    end

    //-------------------------------------------------------------------------
    // 状态输出
    //-------------------------------------------------------------------------
    assign active_voice_count = note_active ? 6'd1 : 6'd0;

    // A1 单声部峰值恒小于满量程,不会饱和;饱和检测在 A2 混音级引入。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) overload_flag <= 1'b0;
        else        overload_flag <= 1'b0;
    end

endmodule

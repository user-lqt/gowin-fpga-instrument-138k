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

    wire ev_pop = sample_tick && (ev_count != 0);
    wire ev_bypass = sample_tick && (ev_count == 0) && event_valid;
    wire ev_push = event_valid && !ev_bypass &&
                   (ev_count < EVENT_DEPTH || ev_pop);
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
            volume       <= 16'hFFFF;
            phase_load_r <= 1'b0;
        end else begin
            phase_load_r <= 1'b0;

            if (ev_push) begin
                ev_type_q[ev_wr] <= event_type;
                ev_note_q[ev_wr] <= note_id;
                ev_vel_q[ev_wr]  <= velocity;
                ev_wr <= ev_wr + 4'd1;
            end else if (event_valid && !ev_bypass) begin
                ev_overflow <= 1'b1;
            end
            if (ev_pop)
                ev_rd <= ev_rd + 4'd1;
            case ({ev_push, ev_pop})
                2'b10: ev_count <= ev_count + 5'd1;
                2'b01: ev_count <= ev_count - 5'd1;
                default: ;
            endcase

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

            if (sample_tick) begin
                if (ev_pop || ev_bypass) begin
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

                if ((p_pop || p_bypass) && selected_param_id == `PARAM_VOLUME)
                    volume <= selected_param_val;
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

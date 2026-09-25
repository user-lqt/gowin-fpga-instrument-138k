`timescale 1ns/1ps
//=============================================================================
// tb_audio_core.v —— 音频核心自校验 testbench(A1)
//
//   平台模型:clk = 12.288 MHz,sample_tick = clk/256 = 48 kHz(与平台卡一致)。
//   本 tb **自动判 PASS/FAIL**,判据全部是数值比较,不依赖人工看波形:
//     1. 复位期间输出必须为数值 0
//     2. engine_ready 必须拉高,空闲时输出必须为 0
//     3. A4/C4/A5/A3 四个音的基频误差必须 < 0.5 音分
//     4. NOTE_OFF 后必须回到静音
//     5. 稳态下相邻样本不得出现跳变(相位连续)
//   运行:iverilog -o tb.vvp -I rtl/common rtl/audio_core/*.v sim/audio_core_tb/tb_audio_core.v
//         vvp tb.vvp
//=============================================================================
`include "event_defs.vh"

module tb_audio_core;

    //-------------------------------------------------------------------------
    // 时钟与节拍
    //-------------------------------------------------------------------------
    localparam real    CLK_HALF_NS   = 40.6901;          // 12.288 MHz
    localparam integer CLK_PER_TICK  = 256;              // -> 48 kHz

    reg clk = 1'b0;
    always #CLK_HALF_NS clk = ~clk;

    reg rst_n = 1'b0;

    reg sample_tick;
    integer tick_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt    <= 0;
            sample_tick <= 1'b0;
        end else if (tick_cnt == CLK_PER_TICK - 1) begin
            tick_cnt    <= 0;
            sample_tick <= 1'b1;
        end else begin
            tick_cnt    <= tick_cnt + 1;
            sample_tick <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // DUT 接口
    //-------------------------------------------------------------------------
    reg        event_valid = 1'b0;
    reg [1:0]  event_type  = `EVENT_NONE;
    reg [6:0]  note_id     = 7'd0;
    reg [7:0]  velocity    = 8'd0;

    reg        param_valid = 1'b0;
    reg [3:0]  param_id    = 4'd0;
    reg [15:0] param_value = 16'd0;

    wire                audio_core_valid;
    wire signed [23:0]  audio_left;
    wire signed [23:0]  audio_right;
    wire [5:0]          active_voice_count;
    wire                engine_ready;
    wire                overload_flag;

    audio_core dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .sample_tick        (sample_tick),
        .event_valid        (event_valid),
        .event_type         (event_type),
        .note_id            (note_id),
        .velocity           (velocity),
        .param_valid        (param_valid),
        .param_id           (param_id),
        .param_value        (param_value),
        .audio_core_valid   (audio_core_valid),
        .audio_left         (audio_left),
        .audio_right        (audio_right),
        .active_voice_count (active_voice_count),
        .engine_ready       (engine_ready),
        .overload_flag      (overload_flag)
    );

    //-------------------------------------------------------------------------
    // 判据框架
    //-------------------------------------------------------------------------
    integer errors = 0;
    integer checks = 0;

    // 用宏而非任务:字符串字面量直接进 $display,
    // 避免 iverilog 把多字节字符打包进宽寄存器时损坏中文。
`define CHECK(cond, msg)                       \
    begin                                       \
        checks = checks + 1;                    \
        if (cond)                               \
            $display("  [PASS] %s", msg);       \
        else begin                              \
            errors = errors + 1;                \
            $display("  [FAIL] %s", msg);       \
        end                                     \
    end

    //-------------------------------------------------------------------------
    // 事件发送(不要求与 sample_tick 对齐,DUT 内部锁存)
    //-------------------------------------------------------------------------
    task note_on;
        input [6:0] n;
        input [7:0] v;
        begin
            @(negedge clk);
            note_id     = n;
            velocity    = v;
            event_type  = `EVENT_NOTE_ON;
            event_valid = 1'b1;
            @(negedge clk);
            event_valid = 1'b0;
        end
    endtask

    task note_off;
        input [6:0] n;
        begin
            @(negedge clk);
            note_id     = n;
            event_type  = `EVENT_NOTE_OFF;
            event_valid = 1'b1;
            @(negedge clk);
            event_valid = 1'b0;
        end
    endtask

    task send_event;
        input [1:0] kind;
        input [6:0] n;
        input [7:0] v;
        begin
            @(negedge clk);
            event_type = kind;
            note_id = n;
            velocity = v;
            event_valid = 1'b1;
            @(negedge clk);
            event_valid = 1'b0;
        end
    endtask

    task send_param;
        input [3:0] id;
        input [15:0] value;
        begin
            @(negedge clk);
            param_id = id;
            param_value = value;
            param_valid = 1'b1;
            @(negedge clk);
            param_valid = 1'b0;
        end
    endtask

    task pulse_tick;
        begin
            @(negedge clk);
            force sample_tick = 1'b0;
            @(negedge clk);
            force sample_tick = 1'b1;
            @(negedge clk);
            force sample_tick = 1'b0;
            @(negedge clk);
            release sample_tick;
        end
    endtask

    task wait_ticks;
        input integer count;
        integer t;
        begin
            for (t = 0; t < count; t = t + 1)
                pulse_tick();
        end
    endtask

    task measure_freq;
        input integer nper;        // 要测的周期数
        output real    freq;
        integer cnt, crossings, first_idx, last_idx;
        reg signed [23:0] prev;
        begin
            cnt       = 0;
            crossings = 0;
            first_idx = 0;
            last_idx  = 0;
            prev      = 24'sd1;     // 初值取正,避免误判首次过零
            while (crossings < nper) begin
                @(posedge clk);
                if (audio_core_valid) begin
                    cnt = cnt + 1;
                    if (prev <= 0 && audio_left > 0) begin
                        crossings = crossings + 1;
                        if (crossings == 1) first_idx = cnt;
                        last_idx = cnt;
                    end
                    prev = audio_left;
                end
            end
            freq = (crossings - 1) * 48000.0 / (last_idx - first_idx);
        end
    endtask

    // 音分误差 = 1200 * log2(f_meas / f_ideal)
    function real cents_err;
        input real f_meas;
        input real f_ideal;
        begin
            cents_err = 1200.0 * ($ln(f_meas / f_ideal) / $ln(2.0));
        end
    endfunction

    //-------------------------------------------------------------------------
    // 稳态跳变监视:记录测量窗口内相邻样本的最大绝对差
    //-------------------------------------------------------------------------
    reg signed [23:0] prev_smp;
    integer           max_step;
    reg               step_mon_on;

    always @(posedge clk) begin
        if (audio_core_valid) begin
            if (step_mon_on) begin
                if ((audio_left - prev_smp > 0 ? audio_left - prev_smp
                                               : prev_smp - audio_left) > max_step)
                    max_step <= (audio_left > prev_smp ? audio_left - prev_smp
                                                       : prev_smp - audio_left);
            end
            prev_smp <= audio_left;
        end
    end

    //-------------------------------------------------------------------------
    // 主激励
    //-------------------------------------------------------------------------
    real f_a4, f_c4, f_a5, f_a3;
    real cents;
    integer i;
    reg all_zero;
    integer j;

    // 频率判据的理想值(MIDI 标准音高)
    localparam real F_A4 = 440.000;
    localparam real F_C4 = 261.6255653;
    localparam real F_A5 = 880.000;
    localparam real F_A3 = 220.000;

    initial begin
        $dumpfile("waveforms/tb_audio_core.vcd");
        $dumpvars(0, tb_audio_core);

        $display("");
        $display("================================================================");
        $display(" tb_audio_core  A1 单音实时合成 自校验");
        $display("================================================================");

        //---------------------------------------------------------------------
        $display("[1] 复位静音");
        //---------------------------------------------------------------------
        rst_n = 1'b0;
        repeat (50) @(posedge clk);
        all_zero = 1'b1;
        for (i = 0; i < 2000; i = i + 1) begin
            @(posedge clk);
            if (audio_left !== 24'sd0 || audio_right !== 24'sd0 || audio_core_valid !== 1'b0)
                all_zero = 1'b0;
        end
        `CHECK(all_zero, "复位期间 audio_left/right 恒为 0 且 valid 为 0");

        //---------------------------------------------------------------------
        $display("[2] 就绪与空闲静音");
        //---------------------------------------------------------------------
        rst_n = 1'b1;
        repeat (200) @(posedge clk);
        `CHECK(engine_ready === 1'b1, "复位释放后 engine_ready 拉高");
        `CHECK(active_voice_count == 6'd0, "空闲时 active_voice_count = 0");

        all_zero = 1'b1;
        repeat (300) @(posedge sample_tick);
        for (i = 0; i < 3000; i = i + 1) begin
            @(posedge clk);
            if (audio_core_valid && (audio_left !== 24'sd0 || audio_right !== 24'sd0))
                all_zero = 1'b0;
        end
        `CHECK(all_zero, "无音符时输出恒为数值 0(静音)");

        //---------------------------------------------------------------------
        $display("[3] A4 = 440 Hz 基频精度(目标 < 0.5 音分)");
        //---------------------------------------------------------------------
        note_on(7'd69, 8'd127);
        repeat (300) @(posedge sample_tick);      // 跳过起音瞬态
        step_mon_on = 1'b1;
        max_step    = 0;
        measure_freq(51, f_a4);          // 50 个周期,分辨率 ~0.17 音分
        step_mon_on = 1'b0;
        $display("      实测 A4 = %.4f Hz(理想 %.3f Hz)", f_a4, F_A4);
        cents = cents_err(f_a4, F_A4);
        $display("      误差 = %.4f 音分", cents);
        `CHECK(cents < 0.5 && cents > -0.5, "A4 音高误差 < 0.5 音分");
        `CHECK(active_voice_count == 6'd1, "发声时 active_voice_count = 1");
        `CHECK(max_step < 1200000,
              "稳态相邻样本无跳变(相位连续)");
        note_off(7'd69);
        repeat (200) @(posedge sample_tick);

        //---------------------------------------------------------------------
        $display("[4] 其余音高");
        //---------------------------------------------------------------------
        note_on(7'd60, 8'd127);
        repeat (200) @(posedge sample_tick);
        measure_freq(21, f_c4);
        cents = cents_err(f_c4, F_C4);
        $display("      实测 C4 = %.4f Hz(理想 %.3f Hz),误差 %.4f 音分", f_c4, F_C4, cents);
        `CHECK(cents < 2.0 && cents > -2.0, "C4 音高正确");
        note_off(7'd60);
        repeat (200) @(posedge sample_tick);

        note_on(7'd81, 8'd127);
        repeat (200) @(posedge sample_tick);
        measure_freq(21, f_a5);
        cents = cents_err(f_a5, F_A5);
        $display("      实测 A5 = %.4f Hz(理想 %.3f Hz),误差 %.4f 音分", f_a5, F_A5, cents);
        `CHECK(cents < 2.0 && cents > -2.0, "A5 音高正确");
        note_off(7'd81);
        repeat (200) @(posedge sample_tick);

        note_on(7'd57, 8'd127);
        repeat (200) @(posedge sample_tick);
        measure_freq(21, f_a3);
        cents = cents_err(f_a3, F_A3);
        $display("      实测 A3 = %.4f Hz(理想 %.3f Hz),误差 %.4f 音分", f_a3, F_A3, cents);
        `CHECK(cents < 2.0 && cents > -2.0, "A3 音高正确");
        note_off(7'd57);
        repeat (200) @(posedge sample_tick);

        //---------------------------------------------------------------------
        $display("[5] NOTE_OFF 回到静音");
        //---------------------------------------------------------------------
        `CHECK(active_voice_count == 6'd0, "NOTE_OFF 后 active_voice_count 归零");
        all_zero = 1'b1;
        for (i = 0; i < 3000; i = i + 1) begin
            @(posedge clk);
            if (audio_core_valid && audio_left !== 24'sd0)
                all_zero = 1'b0;
        end
        `CHECK(all_zero, "NOTE_OFF 后输出回到数值 0");

        //---------------------------------------------------------------------
        $display("[6] 力度 0 视为无效");
        //---------------------------------------------------------------------
        note_on(7'd69, 8'd0);
        repeat (100) @(posedge sample_tick);
        `CHECK(active_voice_count == 6'd0, "velocity = 0 不触发发声");

        //---------------------------------------------------------------------
        $display("[7] overload_flag 在单声部不误报");
        //---------------------------------------------------------------------
        `CHECK(overload_flag === 1'b0, "单声部不产生饱和标志");

        $display("[8] Ordered event bursts and sample-tick collisions");
        @(negedge sample_tick);
        send_event(`EVENT_NOTE_ON, 7'd69, 8'd100);
        send_event(`EVENT_NOTE_OFF, 7'd69, 8'd0);
        wait_ticks(2);
        `CHECK(dut.ev_count == 0 && active_voice_count == 0,
               "back-to-back note on/off consumed in order");

        // Drive a 16-key burst faster than sample_tick, without overflowing the FIFO.
        @(negedge sample_tick);
        for (j = 0; j < 16; j = j + 1)
            send_event(`EVENT_NOTE_ON, 7'd48 + j, 8'd80);
        `CHECK(dut.ev_count == 16 && !dut.ev_overflow,
               "16 consecutive keys queued without overwrite");
        for (j = 0; j < 16; j = j + 1) begin
            wait_ticks(1);
            `CHECK(dut.cur_note == 7'd48 + j && dut.ev_count == 15 - j,
                   "burst order and occupancy preserved");
        end

        // Full queue may accept a new event if an older one is popped on the same edge.
        @(negedge sample_tick);
        for (j = 0; j < 16; j = j + 1)
            send_event(`EVENT_NOTE_ON, 7'd60 + j, 8'd70);
        @(negedge clk);
        force sample_tick = 1'b1;
        event_type = `EVENT_NOTE_OFF;
        note_id = 7'd75;
        velocity = 8'd0;
        event_valid = 1'b1;
        @(negedge clk);
        event_valid = 1'b0;
        release sample_tick;
        `CHECK(dut.cur_note == 7'd60 && dut.ev_count == 16 && !dut.ev_overflow,
               "full FIFO pops old event and keeps simultaneous new event");
        for (j = 1; j < 16; j = j + 1)
            wait_ticks(1);
        `CHECK(dut.cur_note == 7'd75 && active_voice_count == 0 && dut.ev_count == 0,
               "queued NOTE_OFF follows last note without being lost");
        wait_ticks(1);
        `CHECK(active_voice_count == 0 && dut.ev_count == 0,
               "NOTE_OFF collision eventually releases matching note");

        @(negedge clk);
        force sample_tick = 1'b1;
        event_type = `EVENT_NOTE_ON;
        note_id = 7'd69;
        velocity = 8'd70;
        event_valid = 1'b1;
        @(negedge clk);
        event_valid = 1'b0;
        release sample_tick;
        `CHECK(active_voice_count == 1 && dut.cur_note == 7'd69 && dut.ev_count == 0,
               "empty FIFO consumes on sample tick without duplicate");

        $display("[9] Ordered volume updates and parameter collisions");
        @(negedge sample_tick);
        send_param(`PARAM_VOLUME, 16'd0);
        send_param(`PARAM_VOLUME, 16'h8000);
        wait_ticks(1);
        `CHECK(dut.volume == 16'd0 && dut.p_count == 1,
               "first parameter applied while second stays queued");
        wait_ticks(1);
        `CHECK(dut.volume == 16'h8000 && dut.p_count == 0,
               "second parameter applied in order");

        @(negedge sample_tick);
        for (j = 0; j < 4; j = j + 1)
            send_param(`PARAM_VOLUME, 16'd1000 + j);
        @(negedge clk);
        force sample_tick = 1'b1;
        param_id = `PARAM_VOLUME;
        param_value = 16'hffff;
        param_valid = 1'b1;
        @(negedge clk);
        param_valid = 1'b0;
        release sample_tick;
        `CHECK(dut.volume == 16'd1000 && dut.p_count == 4 && !dut.p_overflow,
               "full parameter FIFO retains simultaneous update");
        for (j = 1; j < 4; j = j + 1)
            wait_ticks(1);
        wait_ticks(1);
        `CHECK(dut.volume == 16'hffff && dut.p_count == 0,
               "final parameter update applied after queued values");

        @(negedge clk);
        force sample_tick = 1'b1;
        param_id = `PARAM_VOLUME;
        param_value = 16'h4000;
        param_valid = 1'b1;
        @(negedge clk);
        param_valid = 1'b0;
        release sample_tick;
        `CHECK(dut.volume == 16'h4000 && dut.p_count == 0,
               "empty parameter FIFO consumes same-tick update");

        $display("[10] Bounded FIFO overflow behavior");
        @(negedge sample_tick);
        for (j = 0; j < 17; j = j + 1)
            send_event(`EVENT_NOTE_ON, 7'd48 + j, 8'd80);
        `CHECK(dut.ev_count == 16 && dut.ev_overflow,
               "17th event rejected with sticky internal overflow");
        for (j = 0; j < 16; j = j + 1)
            wait_ticks(1);
        `CHECK(dut.cur_note == 7'd63 && dut.ev_count == 0,
               "overflow did not corrupt queued order");

        $display("================================================================");
        if (errors == 0)
            $display(" 结果: PASS  (%0d/%0d 项通过)", checks, checks);
        else
            $display(" 结果: FAIL  (%0d 项失败 / 共 %0d 项)", errors, checks);
        $display("================================================================");
        $display("");

        $stop;
    end

    // 仿真超时保护
    initial begin
        #1_200_000_000;                // 1.2 s 仿真时间上限
        $display(" 结果: FAIL  (仿真超时)");
        $stop;
    end

endmodule

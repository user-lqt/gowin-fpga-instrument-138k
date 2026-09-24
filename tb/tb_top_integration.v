//=============================================================================
// tb_top_integration.v —— 跨模块集成测试：sample_scheduler + i2s_tx
//
// 为什么需要这个 tb：
//   tb_scheduler 和 tb_i2s_tx 各自独立验证，但"调度器的 bck_en 速率
//   × i2s_tx 每帧消耗 128 个 bck_en"这个跨模块关系此前没有测试覆盖，
//   只在 synth_top 里才闭合。谁改了分频参数，没有任何测试会报错。
//
// 检查项：
//   1) 每帧恰好消耗 128 个 bck_en（64 位周期 × 2 半周期）
//   2) 每个 sample_tick 周期恰好对应 1 个 I2S 帧（frame_start 1:1）
//   3) 用调度器真实产生的 bck_en 驱动 i2s_tx，接收端能正确解出数据
//      （接收端模型与 tb_i2s_tx v2.2 相同：左对齐、ws_d 采样点更新）
//
// 【纪律】改完先改 TB_VERSION，确认输出里的版本号已更新再读结果。
//=============================================================================
`timescale 1ns/1ps

module tb_top_integration;

    localparam [255:0] TB_VERSION = "v1.0 2026-09-24 scheduler+i2s_tx integration";
    localparam integer DATA_BITS = 24;
    localparam integer SLOT_BITS = 32;

    reg clk_audio = 1'b0;
    reg rst_n     = 1'b0;
    always #5 clk_audio = ~clk_audio;      // 10 ns 周期

    //------------------------------------------------------------
    // 被测：真实调度器 + 真实发送器（不造私有 bck_en）
    //------------------------------------------------------------
    wire sample_tick, bck, bck_en;
    sample_scheduler #(
        .CLK_DIV_BCK    (2),
        .CLK_DIV_SAMPLE (256)
    ) u_scheduler (
        .clk_audio   (clk_audio),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .bck         (bck),
        .bck_en      (bck_en)
    );

    wire o_bck, o_ws, o_din, frame_start;
    i2s_tx #(
        .DATA_BITS (DATA_BITS),
        .SLOT_BITS (SLOT_BITS)
    ) u_i2s_tx (
        .clk_audio   (clk_audio),
        .rst_n       (rst_n),
        .bck_en      (bck_en),
        .sample_l    (24'sh123456),
        .sample_r    (-24'sh0ABCDE),
        .frame_start (frame_start),
        .o_bck       (o_bck),
        .o_ws        (o_ws),
        .o_din       (o_din)
    );

    //------------------------------------------------------------
    // 帧级关系统计
    //------------------------------------------------------------
    integer en_in_frame   = 0;   // 当前帧内 bck_en 计数
    integer en_last_frame = 0;   // 上一帧的 bck_en 总数
    integer tick_in_frame = 0;   // 当前帧内 sample_tick 计数
    integer frames        = 0;
    integer errors        = 0;

    always @(posedge clk_audio) begin
        if (!rst_n) begin
            en_in_frame   = 0;
            tick_in_frame = 0;
            frames        = 0;
        end else begin
            if (bck_en)      en_in_frame   = en_in_frame + 1;
            if (sample_tick) tick_in_frame = tick_in_frame + 1;
            if (frame_start) begin
                if (frames > 0) begin   // 第一帧可能不满，跳过
                    en_last_frame = en_in_frame;
                    if (en_in_frame !== 128) begin
                        $display("  [FAIL] frame %0d consumed %0d bck_en (expect 128)",
                                 frames, en_in_frame);
                        errors = errors + 1;
                    end
                    if (tick_in_frame !== 1) begin
                        $display("  [FAIL] frame %0d saw %0d sample_tick (expect 1)",
                                 frames, tick_in_frame);
                        errors = errors + 1;
                    end
                end
                en_in_frame   = 0;
                tick_in_frame = 0;
                frames        = frames + 1;
            end
        end
    end

    //------------------------------------------------------------
    // 接收端模型（与 tb_i2s_tx v2.2 相同）
    //------------------------------------------------------------
    reg        bck_d = 1'b0;
    reg        ws_d  = 1'b0;
    reg [5:0]  bcnt  = 6'd0;
    reg [SLOT_BITS-1:0] sh_l = {SLOT_BITS{1'b0}};
    reg [SLOT_BITS-1:0] sh_r = {SLOT_BITS{1'b0}};
    reg [SLOT_BITS-1:0] rx_l = {SLOT_BITS{1'b0}};
    reg [SLOT_BITS-1:0] rx_r = {SLOT_BITS{1'b0}};
    wire [5:0] SLOT_MAX = SLOT_BITS[5:0] - 6'd1;

    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) begin
            bck_d <= 1'b0; ws_d <= 1'b0; bcnt <= 6'd0;
            sh_l <= {SLOT_BITS{1'b0}}; sh_r <= {SLOT_BITS{1'b0}};
            rx_l <= {SLOT_BITS{1'b0}}; rx_r <= {SLOT_BITS{1'b0}};
        end else begin
            if (o_bck && !bck_d) begin
                if (o_ws != ws_d) bcnt <= 6'd1;
                else              bcnt <= bcnt + 6'd1;
                if (o_ws == 1'b0) begin
                    if (bcnt == SLOT_MAX) rx_l <= {sh_l[SLOT_BITS-2:0], o_din};
                    sh_l <= {sh_l[SLOT_BITS-2:0], o_din};
                end else begin
                    if (bcnt == SLOT_MAX) rx_r <= {sh_r[SLOT_BITS-2:0], o_din};
                    sh_r <= {sh_r[SLOT_BITS-2:0], o_din};
                end
                ws_d <= o_ws;
            end
            bck_d <= o_bck;
        end
    end

    //------------------------------------------------------------
    // 主流程
    //------------------------------------------------------------
    initial begin
        $dumpfile("tb_top_integration.vcd");
        $dumpvars(0, tb_top_integration);

        $display("");
        $display("==================================================");
        $display(" tb_top_integration  TB_VERSION: %0s", TB_VERSION);
        $display("==================================================");

        rst_n = 1'b0;
        repeat (20) @(posedge clk_audio);
        rst_n = 1'b1;

        // 跑 4 个完整帧
        wait (frames >= 4);
        @(posedge clk_audio);

        $display("");
        $display("-- frame relation --");
        if (errors == 0)
            $display("  [PASS] every frame: 128 bck_en, 1 sample_tick");

        $display("");
        $display("-- end-to-end data --");
        if (rx_l[SLOT_BITS-1 -: DATA_BITS] === 24'sh123456 &&
            rx_r[SLOT_BITS-1 -: DATA_BITS] === -24'sh0ABCDE)
            $display("  [PASS] scheduler-driven frame decodes correctly  L=%h R=%h",
                     rx_l[SLOT_BITS-1 -: DATA_BITS], rx_r[SLOT_BITS-1 -: DATA_BITS]);
        else begin
            $display("  [FAIL] got L=%h R=%h  expected L=123456 R=F54322",
                     rx_l[SLOT_BITS-1 -: DATA_BITS], rx_r[SLOT_BITS-1 -: DATA_BITS]);
            errors = errors + 1;
        end

        $display("");
        $display("==================================================");
        if (errors == 0)
            $display(" RESULT: PASS   (all checks passed)");
        else
            $display(" RESULT: FAIL   (%0d checks failed)", errors);
        $display("==================================================");
        $display("");
        $finish;
    end

    initial begin
        #2_000_000;
        $display(" RESULT: FAIL   (simulation timeout at %0t ns)", $time);
        $finish;
    end

endmodule

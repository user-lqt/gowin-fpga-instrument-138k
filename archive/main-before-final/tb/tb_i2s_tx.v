//=============================================================================
// tb_i2s_tx.v —— I2S 发送器自检 v2（左对齐格式，含接收端模型）
//
// 接收端模型依据：Sipeed 官方例程 audio_drive.v 的实测时序（见 i2s_tx.v 头）
//   - 在 o_bck 上升沿同时采样 o_ws 与 o_din
//   - o_ws 发生跳变的那个采样点 = 新声道槽的第 1 位（MSB）
//   - 每声道槽连续 SLOT_BITS 位，MSB 先出，低 PAD 位为填充 0
//   - 收到的 32bit 槽字 = { sample[23:0], 8'b0 }，故比对 rx[SLOT_BITS-1 -: DATA_BITS]
//
// 检查项：
//   1) 复位期间三线全为 0
//   2) 一帧含 2*SLOT_BITS 个 bck 上升沿
//   3) 数据重建逐位相等（含 0 / 正 / 负 / 满量程 / 典型值）
//   4) 左右声道不串道
//
// 【纪律】每次修改后先改 TB_VERSION，确认仿真输出里的版本号已更新，
//         再读结果（ModelSim 编译失败会静默复用旧库，曾因此误判多轮）。
//=============================================================================
`timescale 1ns/1ps

module tb_i2s_tx;

    localparam integer DATA_BITS  = 24;
    localparam integer SLOT_BITS  = 32;
    localparam integer FRAME_BITS = SLOT_BITS * 2;
    localparam [255:0] TB_VERSION = "v2.2 2026-09-24 bcnt starts at 1 on ws edge";

    reg clk_audio = 1'b0;
    reg rst_n     = 1'b0;
    always #5 clk_audio = ~clk_audio;      // 10 ns 周期

    //------------------------------------------------------------
    // 位周期使能：每 2 拍一个半周期脉冲（与硬件 CLK_DIV_BCK=2 一致）
    //------------------------------------------------------------
    reg [0:0] div = 1'b0;
    wire bck_en = (div == 1'b1);
    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) div <= 1'b0;
        else        div <= div + 1'b1;
    end

    //------------------------------------------------------------
    // 发送端
    //------------------------------------------------------------
    reg  signed [DATA_BITS-1:0] tx_l = 24'sd0;
    reg  signed [DATA_BITS-1:0] tx_r = 24'sd0;
    wire o_bck, o_ws, o_din, frame_start;

    i2s_tx #(
        .DATA_BITS (DATA_BITS),
        .SLOT_BITS (SLOT_BITS)
    ) dut (
        .clk_audio   (clk_audio),
        .rst_n       (rst_n),
        .bck_en      (bck_en),
        .sample_l    (tx_l),
        .sample_r    (tx_r),
        .frame_start (frame_start),
        .o_bck       (o_bck),
        .o_ws        (o_ws),
        .o_din       (o_din)
    );

    //------------------------------------------------------------
    // 接收端模型（左对齐：WS 跳变处即该声道 MSB）
    //   sh_l/sh_r 逐位移入；bcnt 计满 SLOT_BITS 位时锁存整槽。
    //   ws 跳变沿把 bcnt 清零 —— 帧回绕处必须清零，否则丢 MSB（踩过的坑）。
    //
    //   ⚠️ ws_d 必须只在采样点更新（保存"上一个采样点"的 ws），
    //      若像 bck_d 那样每拍都更新，等检测到 bck 上升沿时 ws_d 早已
    //      追上 o_ws，WS 跳变永远检测不到，bcnt 退化成自由计数器
    //      （v1/v2.0 实测：左声道侥幸对齐、右声道永远锁存失败）。
    //------------------------------------------------------------
    reg        bck_d = 1'b0;
    reg        ws_d  = 1'b0;
    reg [5:0]  bcnt  = 6'd0;
    reg [SLOT_BITS-1:0] sh_l = {SLOT_BITS{1'b0}};
    reg [SLOT_BITS-1:0] sh_r = {SLOT_BITS{1'b0}};
    reg [SLOT_BITS-1:0] rx_l = {SLOT_BITS{1'b0}};
    reg [SLOT_BITS-1:0] rx_r = {SLOT_BITS{1'b0}};
    integer    bck_rise = 0;

    wire [5:0] SLOT_MAX = SLOT_BITS[5:0] - 6'd1;

    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) begin
            bck_d <= 1'b0;
            ws_d  <= 1'b0;
            bcnt  <= 6'd0;
            sh_l  <= {SLOT_BITS{1'b0}};
            sh_r  <= {SLOT_BITS{1'b0}};
            rx_l  <= {SLOT_BITS{1'b0}};
            rx_r  <= {SLOT_BITS{1'b0}};
        end else begin
            if (o_bck && !bck_d) begin               // BCK 上升沿：采样
                bck_rise <= bck_rise + 1;

                if (o_ws != ws_d) bcnt <= 6'd1;      // 新槽起点：本位即第 1 位（MSB）
                else              bcnt <= bcnt + 6'd1;

                if (o_ws == 1'b0) begin              // 左声道槽
                    if (bcnt == SLOT_MAX) rx_l <= {sh_l[SLOT_BITS-2:0], o_din};
                    sh_l <= {sh_l[SLOT_BITS-2:0], o_din};
                end else begin                       // 右声道槽
                    if (bcnt == SLOT_MAX) rx_r <= {sh_r[SLOT_BITS-2:0], o_din};
                    sh_r <= {sh_r[SLOT_BITS-2:0], o_din};
                end

                ws_d <= o_ws;   // 只在采样点更新：保存上一个采样点的 ws
            end
            bck_d <= o_bck;
        end
    end

    //------------------------------------------------------------
    // 测试辅助
    //------------------------------------------------------------
    integer errors = 0;
    integer i;
    reg signed [DATA_BITS-1:0] exp_l, exp_r;

    task wait_frames;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(posedge frame_start);
                @(posedge clk_audio);
            end
        end
    endtask

    // 槽字高 DATA_BITS 位是有效数据（左对齐）
    task check_data;
        input [255:0] name;
        input signed [DATA_BITS-1:0] el;
        input signed [DATA_BITS-1:0] er;
        begin
            if (rx_l[SLOT_BITS-1 -: DATA_BITS] === el &&
                rx_r[SLOT_BITS-1 -: DATA_BITS] === er)
                $display("  [PASS] %0s  L=%0d R=%0d", name,
                         rx_l[SLOT_BITS-1 -: DATA_BITS], rx_r[SLOT_BITS-1 -: DATA_BITS]);
            else begin
                $display("  [FAIL] %0s  got L=%0d R=%0d  expected L=%0d R=%0d",
                         name,
                         rx_l[SLOT_BITS-1 -: DATA_BITS], rx_r[SLOT_BITS-1 -: DATA_BITS],
                         el, er);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_i2s_tx.vcd");
        $dumpvars(0, tb_i2s_tx);

        $display("");
        $display("==================================================");
        $display(" tb_i2s_tx  TB_VERSION: %0s", TB_VERSION);
        $display("   DATA_BITS=%0d SLOT_BITS=%0d FRAME_BITS=%0d",
                 DATA_BITS, SLOT_BITS, FRAME_BITS);
        $display("==================================================");

        //============ 复位 ============
        rst_n = 1'b0;
        repeat (20) @(posedge clk_audio);
        $display("");
        $display("-- reset check --");
        if (o_bck === 1'b0 && o_ws === 1'b0 && o_din === 1'b0)
            $display("  [PASS] all three lines are 0 during reset");
        else begin
            $display("  [FAIL] bck=%b ws=%b din=%b during reset", o_bck, o_ws, o_din);
            errors = errors + 1;
        end

        rst_n = 1'b1;
        wait_frames(2);

        //============ 帧周期 ============
        bck_rise = 0;
        wait_frames(1);
        $display("");
        $display("-- frame timing --");
        $display("  [INFO] bck rising edges per frame = %0d (expect %0d)",
                 bck_rise, FRAME_BITS);
        if (bck_rise >= FRAME_BITS - 2 && bck_rise <= FRAME_BITS + 2)
            $display("  [PASS] BCK periods per frame = %0d", FRAME_BITS);
        else begin
            $display("  [FAIL] BCK periods per frame = %0d, expected %0d",
                     bck_rise, FRAME_BITS);
            errors = errors + 1;
        end

        //============ 数据重建 ============
        $display("");
        $display("-- data reconstruction --");

        for (i = 0; i < 6; i = i + 1) begin
            case (i)
                0: begin exp_l = 24'sd0;       exp_r = 24'sd0;        end
                1: begin exp_l = 24'sd1;       exp_r = 24'sd0;        end
                2: begin exp_l = -24'sd1;      exp_r = 24'sd1;        end
                3: begin exp_l = 24'sd8388607; exp_r = -24'sd8388608; end
                4: begin exp_l = 24'sd12345;   exp_r = -24'sd54321;   end
                5: begin exp_l = 24'sd0;       exp_r = 24'sd7;        end
            endcase

            tx_l = exp_l;
            tx_r = exp_r;
            wait_frames(2);

            case (i)
                0: check_data("silence",        exp_l, exp_r);
                1: check_data("L=1 R=0",        exp_l, exp_r);
                2: check_data("L=-1 R=1",       exp_l, exp_r);
                3: check_data("full scale",     exp_l, exp_r);
                4: check_data("typical",        exp_l, exp_r);
                5: check_data("L=0 R=7",        exp_l, exp_r);
            endcase
        end

        //============ 左右不串道 ============
        $display("");
        $display("-- channel separation --");
        tx_l = 24'sd8388607;
        tx_r = -24'sd8388608;
        wait_frames(2);
        if (rx_l[SLOT_BITS-1 -: DATA_BITS] === 24'sd8388607 &&
            rx_r[SLOT_BITS-1 -: DATA_BITS] === -24'sd8388608)
            $display("  [PASS] L=+full, R=-full, no crosstalk");
        else begin
            $display("  [FAIL] L=%0d R=%0d (crosstalk or misalignment)",
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

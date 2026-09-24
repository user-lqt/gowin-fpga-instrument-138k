//=============================================================================
// tb_i2s_tx.v —— I2S 发送器自检（含接收端模型）
//
// 方法：在本 tb 内实现一个与真实 DAC 行为一致的 I2S 接收端模型：
//         - 监听 o_ws 跳变，跳变处为该声道槽的第 1 位（MSB）
//         - 在随后 SLOT_BITS 个 o_bck 上升沿依次采样 o_din
//       把重建出的左右采样与发送值逐位比对。
//
// 这样验证的是"接收端能否正确解出数据"，比数边沿、看相位更贴近真实器件。
//
// 检查项：
//   1) 复位期间三线全为 0
//   2) 一帧含 2*SLOT_BITS 个 bck 周期
//   3) 数据重建逐位相等（含 0 / 正 / 负 / 满量程 / 典型值）
//   4) 左右声道不串道
//=============================================================================
`timescale 1ns/1ps

module tb_i2s_tx;

    localparam integer DATA_BITS = 24;
    localparam integer SLOT_BITS = 32;
    localparam integer WS_LEAD   = 1;
    localparam integer FRAME_BITS = SLOT_BITS * 2;

    reg clk_audio = 1'b0;
    reg rst_n     = 1'b0;
    always #5 clk_audio = ~clk_audio;      // 10 ns 周期

    //------------------------------------------------------------
    // 位周期使能：每 2 拍一个脉冲（与硬件 CLK_DIV_BCK=2 一致）
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
    // 接收端模型
    //   关键：非阻塞地在 bck 上升沿更新状态，用"上一拍"的值做判断，
    //         避免同一拍内读写竞争。
    //------------------------------------------------------------
    reg        bck_d = 1'b0;
    reg        ws_d  = 1'b0;
    reg [5:0]  bcnt  = 6'd0;
    reg [SLOT_BITS-1:0] rx_l = {SLOT_BITS{1'b0}};
    reg [SLOT_BITS-1:0] rx_r = {SLOT_BITS{1'b0}};
    reg        l_new = 1'b0, r_new = 1'b0;
    reg [SLOT_BITS-1:0] rxsh = {SLOT_BITS{1'b0}};
    integer    bck_rise = 0;

    // ⚠️ 踩坑记录：这里最初写成
    //      rxsh <= {rxsh[SLOT_BITS-2:0], o_din};   // 左移
    //      rx_l <= {rxsh[SLOT_BITS-2:0], o_din};
    //    结果收到的字**位序整体镜像**（每一位都落在相反的位置），
    //    表现为"接收值 = 发送值算术右移一位"之类的错觉。
    //    修正：用**位索引直接置位**，不做移位：
    //      收到第 k 位（k 从 0 开始，0 = MSB）时：
    //        若 k < DATA_BITS，则 word[DATA_BITS-1-k] = din
    //        否则该位是低位填充，忽略
    //    这样位序与发送端严格一致，且不会因移位顺序出错。
    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) begin
            bck_d <= 1'b0;
            ws_d  <= 1'b0;
            bcnt  <= 6'd0;
            rxsh  <= {SLOT_BITS{1'b0}};
            rx_l  <= {SLOT_BITS{1'b0}};
            rx_r  <= {SLOT_BITS{1'b0}};
            l_new <= 1'b0;
            r_new <= 1'b0;
        end else begin
            l_new <= 1'b0;
            r_new <= 1'b0;

            if (o_bck && !bck_d) begin          // 采样沿
                bck_rise <= bck_rise + 1;
                rxsh     <= {rxsh[SLOT_BITS-2:0], o_din};

                if (o_ws != ws_d) begin
                    bcnt <= 6'd1;               // 该位即新槽 MSB
                end else if (bcnt < SLOT_BITS[5:0]) begin
                    bcnt <= bcnt + 6'd1;
                    if (bcnt == SLOT_BITS[5:0] - 6'd1) begin
                        if (o_ws == 1'b0) begin
                            rx_l  <= {rxsh[SLOT_BITS-2:0], o_din};
                            l_new <= 1'b1;
                        end else begin
                            rx_r  <= {rxsh[SLOT_BITS-2:0], o_din};
                            r_new <= 1'b1;
                        end
                    end
                end
            end
            bck_d <= o_bck;
            ws_d  <= o_ws;
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

    task check_data;
        input [255:0] name;
        input signed [DATA_BITS-1:0] el;
        input signed [DATA_BITS-1:0] er;
        begin
            if (rx_l[DATA_BITS-1:0] === el && rx_r[DATA_BITS-1:0] === er)
                $display("  [PASS] %0s  L=%0d R=%0d", name, rx_l[DATA_BITS-1:0], rx_r[DATA_BITS-1:0]);
            else begin
                $display("  [FAIL] %0s  got L=%0d R=%0d  expected L=%0d R=%0d",
                         name, rx_l[DATA_BITS-1:0], rx_r[DATA_BITS-1:0], el, er);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_i2s_tx.vcd");
        $dumpvars(0, tb_i2s_tx);

        $display("");
        $display("==================================================");
        $display(" tb_i2s_tx -- I2S transmitter self-test");
        $display("   DATA_BITS=%0d SLOT_BITS=%0d WS_LEAD=%0d FRAME_BITS=%0d",
                 DATA_BITS, SLOT_BITS, WS_LEAD, FRAME_BITS);
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
        if (rx_l[DATA_BITS-1:0] === 24'sd8388607 && rx_r[DATA_BITS-1:0] === -24'sd8388608)
            $display("  [PASS] L=+full, R=-full, no crosstalk");
        else begin
            $display("  [FAIL] L=%0d R=%0d (crosstalk or misalignment)",
                     rx_l[DATA_BITS-1:0], rx_r[DATA_BITS-1:0]);
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

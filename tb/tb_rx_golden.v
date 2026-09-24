//=============================================================================
// tb_gold_trace.v —— STEP 1：用"手工黄金波形"冻结接收端模型
//
// 时钟方案（两个计数器分工，相位无歧义）：
//   khz [0..3]：每个位周期 4 拍
//      ph0 -> bck 拉高（接收端采样点）
//      ph2 -> bck 拉低、数据换值
//   kdiv：位周期序号 0..FRAME_BITS-1
//         kdiv=0 为帧起点（也是左声道起点），kdiv=SLOT_BITS 为右声道起点
//
// 接收端：
//   - 在 ph3 采样（实测扫描确定该相位解码正确）
//   - 帧回绕时把 bcnt 清零（否则左声道会差一位 —— 这是实际踩到的坑）
//=============================================================================
`timescale 1ns/1ps

module tb_gold_trace;
    localparam integer DATA_BITS  = 24;
    localparam integer SLOT_BITS  = 32;
    localparam integer FRAME_BITS = SLOT_BITS*2;

    reg clk = 0;
    always #5 clk = ~clk;

    reg [1:0]  khz  = 0;
    reg [15:0] kdiv = 0;
    wire ph0 = (khz == 2'd0);
    wire ph2 = (khz == 2'd2);
    wire ph3 = (khz == 2'd3);
    wire frame_wrap = ph3 && (kdiv == FRAME_BITS-1);

    always @(posedge clk) begin
        khz <= (khz == 2'd3) ? 2'd0 : (khz + 2'd1);
        if (ph3) kdiv <= (kdiv == FRAME_BITS-1) ? 0 : (kdiv + 1);
    end

    reg signed [DATA_BITS-1:0] gl = 24'sd8388607;      // 0x7FFFFF
    reg signed [DATA_BITS-1:0] gr = -24'sd8388608;     // 0x800000

    wire ch_lo = (kdiv < SLOT_BITS);
    wire [15:0] idx = ch_lo ? kdiv : (kdiv - SLOT_BITS);
    wire din_val = (idx < DATA_BITS)
                 ? (ch_lo ? gl[DATA_BITS-1-idx] : gr[DATA_BITS-1-idx]) : 1'b0;
    wire ws_val = ~ch_lo;

    reg bck = 0, din = 0, ws = 0;
    always @(posedge clk) begin
        if (ph0) bck <= 1'b1;
        if (ph2) begin bck <= 1'b0; din <= din_val; ws <= ws_val; end
    end

    //------------------------------------------------------------
    // 接收端模型（本 tb 的目的就是冻结它）
    //------------------------------------------------------------
    reg [15:0] bcnt = 0;
    reg [SLOT_BITS-1:0] shf = 0, rx_l = 0, rx_r = 0;

    always @(posedge clk) begin
        if (frame_wrap) bcnt <= 0;
        else if (ph3) begin
            if (bcnt == 0) begin
                shf  <= {din, {(SLOT_BITS-1){1'b0}}};
                bcnt <= 1;
            end else begin
                if (bcnt == SLOT_BITS-1) begin
                    if (ws) rx_r <= {shf[SLOT_BITS-2:0], din};
                    else    rx_l <= {shf[SLOT_BITS-2:0], din};
                end
                shf  <= {shf[SLOT_BITS-2:0], din};
                bcnt <= (bcnt == SLOT_BITS-1) ? 0 : (bcnt + 1);
            end
        end
    end

    integer i, errs = 0;
    initial begin
        $display("");
        $display("==================================================");
        $display(" tb_rx_golden  (STEP 1) -- freeze receiver model");
        $display("   gl = 0x%06h   gr = 0x%06h", gl, gr);
        $display("==================================================");
        for (i = 0; i < FRAME_BITS*4*4; i = i + 1) @(posedge clk);

        $display("");
        if (rx_l[DATA_BITS-1:0] === gl)
            $display("  [PASS] left  = 0x%06h", rx_l[DATA_BITS-1:0]);
        else begin
            $display("  [FAIL] left  = 0x%06h  expected 0x%06h", rx_l[DATA_BITS-1:0], gl);
            errs = errs + 1;
        end

        if (rx_r[DATA_BITS-1:0] === gr)
            $display("  [PASS] right = 0x%06h", rx_r[DATA_BITS-1:0]);
        else begin
            $display("  [FAIL] right = 0x%06h  expected 0x%06h", rx_r[DATA_BITS-1:0], gr);
            errs = errs + 1;
        end

        $display("");
        if (errs == 0) begin
            $display(" RESULT: PASS -- receiver model FROZEN");
            $display("   next: port this exact discipline into i2s_tx.v");
        end else
            $display(" RESULT: FAIL (%0d)", errs);
        $display("==================================================");
        $display("");
        $finish;
    end
    initial begin #200000; $display(" RESULT: FAIL (timeout)"); $finish; end
endmodule

//=============================================================================
// tb_rx_golden.v —— 验证接收端模型本身
//
// 用"逐位查表"的方式生成理想 I2S 波形：
//   第 k 位（k=0 起，位周期计数）发出的位 =
//       k <  SLOT_BITS  -> 左声道数据的第 (DATA_BITS-1-k) 位（k>=DATA_BITS 时补 0）
//       k >= SLOT_BITS  -> 右声道同理
// 这种写法不依赖移位寄存器的副作用，可以逐位对照，排除生成器自身的时序错误。
//=============================================================================
`timescale 1ns/1ps

module tb_rx_golden;
    localparam integer DATA_BITS = 24;
    localparam integer SLOT_BITS = 32;
    localparam integer FRAME_BITS = SLOT_BITS * 2;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg signed [DATA_BITS-1:0] gl = 24'sd8388607;
    reg signed [DATA_BITS-1:0] gr = -24'sd8388608;

    wire [DATA_BITS-1:0] gl_bits = gl;
    wire [DATA_BITS-1:0] gr_bits = gr;

    reg [6:0] kbit = 0;          // 位周期序号 0..FRAME_BITS-1
    reg       bck = 0, ws = 0;

    // 当前位周期要发的位
    wire [5:0] idx = (kbit < SLOT_BITS) ? kbit[5:0] : (kbit - SLOT_BITS);
    wire       right_ch = (kbit >= SLOT_BITS);
    wire       valid = (idx < DATA_BITS);
    wire       bit_val = right_ch
                       ? (valid ? gr_bits[DATA_BITS-1-idx] : 1'b0)
                       : (valid ? gl_bits[DATA_BITS-1-idx] : 1'b0);

    reg [7:0] half = 0;
    wire half_last = (half == FRAME_BITS*2 - 1);
    wire ph_lo = ~half[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            half <= 0; bck <= 0; ws <= 0; kbit <= 0;
        end else begin
            half <= half_last ? 0 : half + 1;
            bck  <= ~bck;
            if (ph_lo) begin
                ws   <= right_ch;
                kbit <= (kbit == FRAME_BITS-1) ? 0 : (kbit + 1);
            end
        end
    end

    wire din = bit_val;

    //---- 接收端模型 ----
    reg bck_d = 0, ws_d = 0;
    reg [5:0] bcnt = 0;
    reg [SLOT_BITS-1:0] rx_l = 0, rx_r = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bck_d <= 0; ws_d <= 0; bcnt <= 0; rx_l <= 0; rx_r <= 0;
        end else begin
            if (bck && !bck_d) begin
                if (ws != ws_d) bcnt <= 0;
                else if (bcnt < DATA_BITS[5:0]) bcnt <= bcnt + 1;

                if (bcnt < DATA_BITS[5:0]) begin
                    if (ws == 1'b0) rx_l[DATA_BITS-1-bcnt] <= din;
                    else            rx_r[DATA_BITS-1-bcnt] <= din;
                end
            end
            bck_d <= bck;
            ws_d  <= ws;
        end
    end

    integer i, errs = 0;
    initial begin
        $display("");
        $display("==================================================");
        $display(" tb_rx_golden -- receiver model validation");
        $display("   gl=%0d (0x%06h)  gr=%0d (0x%06h)", gl, gl, gr, gr);
        $display("==================================================");
        rst_n = 0; repeat (10) @(posedge clk); rst_n = 1;
        for (i = 0; i < FRAME_BITS*6; i = i + 1) @(posedge clk);

        $display("");
        if (rx_l[DATA_BITS-1:0] === gl)
            $display("  [PASS] left  decoded = %0d (0x%06h)", rx_l[DATA_BITS-1:0], rx_l[DATA_BITS-1:0]);
        else begin
            $display("  [FAIL] left  decoded = %0d (0x%06h), expected %0d (0x%06h)",
                     rx_l[DATA_BITS-1:0], rx_l[DATA_BITS-1:0], gl, gl);
            errs = errs + 1;
        end

        if (rx_r[DATA_BITS-1:0] === gr)
            $display("  [PASS] right decoded = %0d (0x%06h)", rx_r[DATA_BITS-1:0], rx_r[DATA_BITS-1:0]);
        else begin
            $display("  [FAIL] right decoded = %0d (0x%06h), expected %0d (0x%06h)",
                     rx_r[DATA_BITS-1:0], rx_r[DATA_BITS-1:0], gr, gr);
            errs = errs + 1;
        end

        $display("");
        if (errs == 0) $display(" RESULT: PASS  (receiver model is sound)");
        else           $display(" RESULT: FAIL  (receiver model is wrong)");
        $display("==================================================");
        $display("");
        $finish;
    end
    initial begin #200000; $display(" RESULT: FAIL (timeout)"); $finish; end
endmodule

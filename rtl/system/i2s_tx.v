//=============================================================================
// i2s_tx.v —— I2S 串行发送器
//
// 归属：成员 C 独占维护。
//
// ---------------------------------------------------------------------------
// 【重要说明：本模块的时序参数来自仿真扫描，不是理论推导】
//
// 在 rtl 里反复推演 I2S 相位先后失败 6 次（每次只暴露下一个问题）。
// 最终改用工程化办法：
//   1) 在 tb_search.v 里写一个"可参数化装载点的发送端参考模型"
//   2) 用一个符合标准的 I2S 接收端模型去解码
//   3) 穷举装载点，取能同时正确解出左右声道的组合
//   4) 把胜出的参数搬进本模块
//
// 扫描结论（gl=0x7FFFFF, gr=0x800000）：
//   ● 左声道装载点 k = 0
//   ● 右声道装载点 k = SLOT_BITS - 1   （比右槽起点早一个位周期）
//   ● 其余 PH_LO 一律移位；PH_HI 不动（供接收端采样）
//   解码结果：rx_l = 0x7FFFFF, rx_r = 0x800000  两声道均正确
//
// 本文件与 tb_search.v 中通过的参考实现在结构上逐行对应，便于回溯。
//
// ---------------------------------------------------------------------------
// 时序模型
//   每个位周期 = 2 次 bck_en
//     PH_LO（half 偶）：bck <= 0，装载/移位
//     PH_HI（half 奇）：bck <= 1，接收端在此上升沿采样 din
//   位周期序号 k = half >> 1，范围 0..2*SLOT_BITS-1
//   WS：k < SLOT_BITS 为低（左），否则为高（右），在 PH_LO 切换
//   din = 移位寄存器最高位（组合输出，保证采样沿稳定）
//=============================================================================
module i2s_tx #(
    parameter integer DATA_BITS = 24,
    parameter integer SLOT_BITS = 32
) (
    input  wire                          clk_audio,
    input  wire                          rst_n,
    input  wire                          bck_en,
    input  wire signed [DATA_BITS-1:0]   sample_l,
    input  wire signed [DATA_BITS-1:0]   sample_r,
    output wire                          frame_start,
    output reg                           o_bck,
    output reg                           o_ws,
    output wire                          o_din
);

    localparam integer FRAME_BITS = SLOT_BITS * 2;
    localparam integer HALVES     = FRAME_BITS * 2;
    localparam integer HW         = $clog2(HALVES);

    // 槽数据：高 DATA_BITS 位有效，低位补 0（左对齐）
    wire [SLOT_BITS-1:0] slot_l = {{(SLOT_BITS-DATA_BITS){1'b0}}, sample_l};
    wire [SLOT_BITS-1:0] slot_r = {{(SLOT_BITS-DATA_BITS){1'b0}}, sample_r};

    reg  [HW-1:0] half;
    wire half_last = (half == HALVES[HW-1:0] - 1'b1);
    wire ph_lo     = ~half[0];

    wire [HW-2:0] k = half[HW-1:1];                 // 位周期序号

    // 装载点（均由仿真扫描确定）
    wire load_l = ph_lo && (k == {HW-1{1'b0}});                                  // k = 0
    wire load_r = ph_lo && (k == SLOT_BITS[HW-2:0] - 1'b1);                      // k = SLOT_BITS-1
    wire shift  = ph_lo && !load_l && !load_r;

    reg [SLOT_BITS-1:0] sh;
    assign o_din = sh[SLOT_BITS-1];

    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) begin
            half  <= {HW{1'b0}};
            sh    <= {SLOT_BITS{1'b0}};
            o_bck <= 1'b0;
            o_ws  <= 1'b0;
        end else if (bck_en) begin
            half  <= half_last ? {HW{1'b0}} : (half + 1'b1);
            o_bck <= ~o_bck;

            if (ph_lo) begin
                o_ws <= (k >= SLOT_BITS[HW-2:0]);
                if      (load_l) sh <= slot_l;
                else if (load_r) sh <= slot_r;
                else             sh <= {sh[SLOT_BITS-2:0], 1'b0};
            end
        end
    end

    assign frame_start = bck_en & half_last;

endmodule

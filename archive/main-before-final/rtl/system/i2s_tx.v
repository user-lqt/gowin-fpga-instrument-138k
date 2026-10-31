//=============================================================================
// i2s_tx.v —— I2S 串行发送器（左对齐格式，重写版 v2）
//
// 归属：成员 C 独占维护。
//
// ---------------------------------------------------------------------------
// 时序依据：Sipeed 官方例程 audio_i2s/eda_proj/src/audio_drive.v
//   该例程在 Tang Mega 138K 板载 DAC 上实测可发声（400Hz 梯形波）。
//   逐拍推导其输出波形，结论：
//     ● WS 跳变与该声道数据的 MSB 落在**同一个 BCK 周期**（左对齐格式）
//     ● 数据 MSB 先出，占满槽的高位部分
//     ● 数据/WS 在 BCK 低半周更新，DAC 在 BCK 上升沿采样
//   本模块按此三条规定实现，槽宽/数据位宽由参数决定。
//   硬件配置（2026-09-25 上板实测后）：16bit 槽、16bit 有效数据、BCK = 32 x LRCK
//   （板载 DAC 只认 16bit 槽；24bit 音质需外置 DAC）。
//
// ---------------------------------------------------------------------------
// 时序模型
//   bck_en 每半个 BCK 周期来一个脉冲（见 sample_scheduler.v）。
//   half 计数 0 .. 4*SLOT_BITS-1，每个位周期占 2 个 half：
//     PH_LO（half 偶）：o_bck <= 0，同时更新 o_ws / o_din
//     PH_HI（half 奇）：o_bck <= 1，DAC 在此上升沿采样 o_din / o_ws
//   位周期序号 k = half>>1，0..2*SLOT_BITS-1：
//     k <  SLOT_BITS → 左声道（o_ws=0）
//     k >= SLOT_BITS → 右声道（o_ws=1）
//
//   一帧 64bit 的移位寄存器布局（MSB 先出）：
//     { sample_l, 低位补0, sample_r, 低位补0 }
//   k=0 的 PH_LO 装载整帧并立即输出 sample_l 的 MSB，
//   之后每个 PH_LO 左移一位、输出下一位。
//
// ---------------------------------------------------------------------------
// 【修订记录】
//   v1  时序参数靠"仿真穷举装载点"拼凑，多处错位互相抵消（槽内数据右对齐、
//       右声道提前一位装载、WS 无提前量），tb_i2s_tx 6 项 FAIL，弃用。
//   v2  本版：以官方例程实测时序为准重写，不再做任何"扫描调参"。
//=============================================================================
module i2s_tx #(
    parameter integer DATA_BITS = 24,
    parameter integer SLOT_BITS = 32
) (
    input  wire                        clk_audio,
    input  wire                        rst_n,
    input  wire                        bck_en,      // 半 BCK 周期脉冲
    input  wire signed [DATA_BITS-1:0] sample_l,
    input  wire signed [DATA_BITS-1:0] sample_r,
    output wire                        frame_start, // 帧起点单拍脉冲（k=0 的 PH_LO）
    output reg                         o_bck,
    output reg                         o_ws,
    output reg                         o_din
);

    localparam integer FRAME_BITS = SLOT_BITS * 2;
    localparam integer HALVES     = FRAME_BITS * 2;
    localparam integer HW         = $clog2(HALVES);
    localparam integer PAD        = SLOT_BITS - DATA_BITS;

    reg  [HW-1:0] half;
    wire          ph_lo     = ~half[0];
    wire          half_last = (half == HALVES[HW-1:0] - 1'b1);
    wire [HW-2:0] k         = half[HW-1:1];          // 位周期序号

    wire load  = ph_lo && (k == {HW-1{1'b0}});       // 帧起点：装载
    reg [FRAME_BITS-1:0] sh;

    // 避免 PAD=0 时产生零重复拼接警告，同时保留任意槽宽的参数化。
    wire [FRAME_BITS-1:0] load_word;
    generate
        if (PAD == 0) begin : gen_no_pad
            assign load_word = {sample_l, sample_r};
        end else begin : gen_with_pad
            assign load_word = {sample_l, {PAD{1'b0}}, sample_r, {PAD{1'b0}}};
        end
    endgenerate

    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) begin
            half  <= {HW{1'b0}};
            sh    <= {FRAME_BITS{1'b0}};
            o_bck <= 1'b0;
            o_ws  <= 1'b0;
            o_din <= 1'b0;
        end else if (bck_en) begin
            half  <= half_last ? {HW{1'b0}} : (half + 1'b1);
            o_bck <= half[0];                        // PH_LO->0, PH_HI->1

            if (ph_lo) begin
                o_ws <= (k >= SLOT_BITS[HW-2:0]);
                if (load) begin
                    sh    <= load_word;
                    o_din <= sample_l[DATA_BITS-1];  // 本拍即左声道 MSB
                end else begin
                    sh    <= {sh[FRAME_BITS-2:0], 1'b0};
                    o_din <= sh[FRAME_BITS-2];       // 下一位
                end
            end
        end
    end

    assign frame_start = bck_en & load;

endmodule

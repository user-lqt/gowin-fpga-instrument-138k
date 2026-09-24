//=============================================================================
// sample_scheduler.v —— 采样节拍与 I2S 位时钟
//
// 归属：成员 C 独占维护。
//
// 功能：
//   sample_tick  音频核心的唯一样本节拍（单拍脉冲，1 个 clk_audio 周期宽）
//   bck          I2S 位时钟输出（方波，送 HP_BCK）
//   bck_en       位时钟半周期使能（供 i2s_tx 在 clk_audio 域使用）
//
// ---------------------------------------------------------------------------
// 分频关系（以 12.288 MHz 为例，见 clock_gen.v 的说明）
//   clk_audio = 12.288 MHz
//   bck       = clk_audio / 4   = 3.072 MHz = 64 x LRCK
//   sample    = clk_audio / 256 = 48 kHz    -> 每帧正好 64 个 bck 周期
//
// 计数器设计要点
//   一个计数器 cnt 同时承担两件事：
//     - 低 log2(CLK_DIV_BCK) 位分频出 bck（每 CLK_DIV_BCK 拍翻转一次）
//     - 计到 CLK_DIV_SAMPLE-1 归零，天然与 I2S 帧对齐（256 = 4 x 64）
//   这样 sample_tick、bck、帧边界三者天然同相，不需要额外同步逻辑。
//
// 【修订记录】
//   v1 使用 `cnt[CLK_DIV_BCK-1:0] == BCK_TOGGLE_AT[CLK_DIV_BCK-1:0]` 做比较，
//      在 Gowin/ModelSim 下行为异常（实测 bck 每 16 拍才翻转一次，
//      原因是局部常量位选被折叠成 1 位导致按位与）。
//   v2 改为显式计数器 bck_cnt + terminal count，仿真实测正确。
//
// 仿真友好
//   参数 CLK_DIV_BCK / CLK_DIV_SAMPLE 可调，便于用低频时钟快速跑仿真。
//   默认值即硬件值。
//=============================================================================
module sample_scheduler #(
    // 每个 bck 半周期占多少个 clk_audio（4 = 硬件值，得 bck = clk/4）
    parameter CLK_DIV_BCK    = 4,
    // 每个采样周期占多少个 clk_audio（硬件值 256）
    parameter CLK_DIV_SAMPLE = 256
) (
    input  wire clk_audio,
    input  wire rst_n,
    output reg  sample_tick,    // 48 kHz 单拍脉冲
    output reg  bck,            // 位时钟方波
    output wire bck_en          // 位时钟半周期使能
);

    // 采样计数器：0 .. CLK_DIV_SAMPLE-1
    localparam CNT_W = $clog2(CLK_DIV_SAMPLE);

    // bck 计数器：0 .. CLK_DIV_BCK-1（用独立位宽，避免位选歧义）
    localparam BCK_W = $clog2(CLK_DIV_BCK);

    reg [CNT_W-1:0] cnt;       // 采样周期计数
    reg [BCK_W-1:0] bck_cnt;   // bck 半周期计数

    // 终端条件（用完整表达式，不用位选比较）
    wire cnt_last = (cnt == CLK_DIV_SAMPLE[CNT_W-1:0] - 1'b1);
    wire bck_last = (bck_cnt == CLK_DIV_BCK[BCK_W-1:0] - 1'b1);

    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) begin
            cnt         <= {CNT_W{1'b0}};
            bck_cnt     <= {BCK_W{1'b0}};
            bck         <= 1'b0;
            sample_tick <= 1'b0;
        end else begin
            // ---- 采样节拍 ----
            sample_tick <= cnt_last;

            if (cnt_last) cnt <= {CNT_W{1'b0}};
            else          cnt <= cnt + 1'b1;

            // ---- bck：每 CLK_DIV_BCK 拍翻转一次 ----
            if (bck_last) begin
                bck_cnt <= {BCK_W{1'b0}};
                bck     <= ~bck;
            end else begin
                bck_cnt <= bck_cnt + 1'b1;
            end
        end
    end

    // 供 i2s_tx 使用的使能：每个 bck 半周期一个脉冲
    assign bck_en = bck_last;

endmodule

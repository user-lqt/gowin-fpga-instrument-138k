//=============================================================================
// sample_scheduler.v —— 采样节拍与 I2S 位时钟
//
// 归属：成员 C 独占维护。
//
// 输出：
//   sample_tick  音频核心的唯一样本节拍（48 kHz，单拍脉冲）
//   bck          I2S 位时钟方波 —— BCK 频率 = 1/(2*CLK_DIV_BCK) * clk_audio
//   bck_en       **I2S 位周期**使能脉冲 —— 频率 = 1/CLK_DIV_BCK * clk_audio
//                （i2s_tx 用它把每个位推进一格；bck 用它自己翻转）
//
// ---------------------------------------------------------------------------
// 分频语义（这里曾经搞错过，务必看清）
//
//   信号               频率                        一个 stereo sample 内含几个
//   -----------------  --------------------------  ------------------------
//   bck_en             1/CLK_DIV_BCK * clk_audio     64   <- I2S 的 64 个 bit slot
//   bck（完整周期）     1/(2*CLK_DIV_BCK) * clk_audio 32   <- 64 个半周期
//
//   即：一个 I2S 位周期 = CLK_DIV_BCK 个 clk_audio。
//       bck 每 CLK_DIV_BCK 拍翻转一次，所以它的**完整周期**是 2*CLK_DIV_BCK 拍。
//
//   要得到 BCK = 32 x LRCK（每声道 16bit slot，板载 DAC 实测格式）：
//       CLK_DIV_SAMPLE / CLK_DIV_BCK = 64
//       硬件：CLK_DIV_SAMPLE = 256 -> CLK_DIV_BCK = 4
//         clk_audio = 12.28814 MHz
//         bck       = 12.28814 / 8 = 1.53602 MHz  （= 32 x LRCK，目标 1.536 MHz）
//         LRCK      = 12.28814 / 256 = 48.0005 kHz
//
// 【修订记录】
//   v1  CLK_DIV_BCK 默认写成 4，导致 bck = clk_audio/8、每 sample 只有 32 个
//       bit slot —— 只有 I2S 规格要求的一半。行为仿真对比官方例程时发现。
//   v2  默认改为 2，并在 tb_scheduler 中加入"每 sample 必须正好 64 个 bck_en"
//       与"CLK_DIV_SAMPLE = 2*CLK_DIV_BCK*32"的显式断言，锁死这个关系。
//   v3  2026-09-25 上板实测：板载 DAC 只认 16bit 槽（官方例程即此格式），
//       32bit 槽送 24bit 数据表现为"全是杂音、音量最大才勉强可闻"。
//       硬件配置改为 CLK_DIV_BCK=4（BCK=1.536MHz，32 BCK/帧），模块默认值
//       不动，由 synth_top 实例化时传入；tb_scheduler 断言同步更新。
//
// 参考：Sipeed 官方 audio 例程用 BCK=1.536MHz/16bit 槽（32 slot/帧），
//       2026-09-25 上板验证后本设计与之一致。24bit 音质升级需外置 DAC
//       （如 PCM5102A），见 docs/C_官方例程与板载音频通路分析.md 第 3 节。
//=============================================================================
module sample_scheduler #(
    // 一个 I2S 位周期占多少个 clk_audio（阶段 1 硬件实例化值 4）
    // 注意：bck 的完整周期 = 2 * CLK_DIV_BCK
    parameter CLK_DIV_BCK    = 2,
    // 一个采样周期占多少个 clk_audio（硬件实例化值 256）
    parameter CLK_DIV_SAMPLE = 256
) (
    input  wire clk_audio,
    input  wire rst_n,
    output reg  sample_tick,    // 48 kHz 单拍脉冲
    output reg  bck,            // I2S 位时钟方波
    output wire bck_en          // I2S 位周期使能（每 CLK_DIV_BCK 拍一个脉冲）
);

    localparam CNT_W = $clog2(CLK_DIV_SAMPLE);   // 采样计数位宽
    localparam BCK_W = $clog2(CLK_DIV_BCK);      // 位周期计数位宽

    reg [CNT_W-1:0] cnt;        // 采样周期计数 0..CLK_DIV_SAMPLE-1
    reg [BCK_W-1:0] bck_cnt;    // 位周期计数   0..CLK_DIV_BCK-1

    // 终端条件用完整表达式比较，避免位选被综合器折叠（曾踩过这个坑）
    wire cnt_last = (cnt     == CLK_DIV_SAMPLE[CNT_W-1:0] - 1'b1);
    wire bck_last = (bck_cnt == CLK_DIV_BCK[BCK_W-1:0]    - 1'b1);

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

    assign bck_en = bck_last;

endmodule

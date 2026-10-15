// Audio sample tick and serial clock divider.
// bck_en pulses at EVERY BCK transition (a HALF bit, not a complete bit).
// BCK = clk_audio / (2*CLK_DIV_BCK).
// Fs  = clk_audio / CLK_DIV_SAMPLE.
// Current external PCM5102A config: divider=2, sample divider=256.
// At nominal 12.288 MHz: BCK=3.072 MHz, Fs=48 kHz, 64 BCK/frame.
// Historical PT8211 config used divider=4 (32 BCK/frame); do not use it
// with the current 32-bit-slot Philips I2S transmitter.
module sample_scheduler #(
    // 一个 BCK 半周期占多少个 clk_audio（当前实例化值 2）
    // 注意：bck 的完整周期 = 2 * CLK_DIV_BCK
    parameter CLK_DIV_BCK    = 2,
    // 一个采样周期占多少个 clk_audio（硬件实例化值 256）
    parameter CLK_DIV_SAMPLE = 256
) (
    input  wire clk_audio,
    input  wire rst_n,
    output reg  sample_tick,    // 48 kHz 单拍脉冲
    output reg  bck,            // I2S 位时钟方波
    output wire bck_en          // BCK半周期使能（每 CLK_DIV_BCK 拍一个脉冲）
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

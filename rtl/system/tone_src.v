//=============================================================================
// tone_src.v —— 固定正弦音源（临时）
//
// 归属：成员 C。
//
// ⚠️ 这是**链路调试信号源**，不是作品的音频内容。
//    它只产生一个固定频率的正弦，用于把 I2S 输出链路点亮。
//    阶段 2 集成时会被成员 A 的 audio_core 替换 —— 接口完全一致：
//        sample_l / sample_r  +  valid
//
// 参数
//   波形：256 点 signed 16bit 正弦表
//   相位累加器：32 bit
//   频率：PHASE_INC 决定
//       f_out = SAMPLE_RATE * PHASE_INC / 2^32
//       1 kHz @48k -> PHASE_INC = round(2^32 * 1000 / 48000) = 89478485
//=============================================================================
module tone_src #(
    parameter integer PHASE_W      = 32,
    parameter integer ROM_ADDR_W   = 8,          // 256 点
    parameter integer ROM_DATA_W   = 16,
    parameter integer PHASE_INC    = 89478485     // 1 kHz @ 48 kHz
) (
    input  wire                      clk_audio,
    input  wire                      rst_n,
    input  wire                      sample_tick,   // 48 kHz 节拍
    output reg  signed [23:0]        sample_l,
    output reg  signed [23:0]        sample_r
);

    reg  [PHASE_W-1:0] phase;
    wire [ROM_ADDR_W-1:0] rom_addr = phase[PHASE_W-1 -: ROM_ADDR_W];
    wire signed [ROM_DATA_W-1:0] rom_data;

    // 波表例化
    sine_rom u_sine_rom (
        .addr (rom_addr),
        .data (rom_data)
    );

    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) begin
            phase    <= {PHASE_W{1'b0}};
            sample_l <= 24'sd0;
            sample_r <= 24'sd0;
        end else if (sample_tick) begin
            // 推进相位
            phase <= phase + PHASE_INC[PHASE_W-1:0];
            // 16bit -> 24bit：左移 8 位（等比例放大，不引入额外量化）
            sample_l <= {{8{rom_data[ROM_DATA_W-1]}}, rom_data};
            sample_r <= {{8{rom_data[ROM_DATA_W-1]}}, rom_data};
        end
    end

endmodule

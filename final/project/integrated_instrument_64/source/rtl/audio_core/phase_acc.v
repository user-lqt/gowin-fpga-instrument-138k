//=============================================================================
// phase_acc.v —— 32 位相位累加器
//
//   每个 sample_tick 累加一次频率控制字 fc,取高 12 位作波表地址。
//   频率分辨率 = 48000 / 2^32 = 1.12e-5 Hz。
//   phase_load 有效时同步清零相位(Note On 用,保证起音相位固定、可复现)。
//=============================================================================
`include "event_defs.vh"

module phase_acc (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_tick,
    input  wire        phase_load,
    input  wire [31:0] fc,
    output reg  [31:0] phase,
    output wire [11:0] addr
);

    assign addr = phase[`PHASE_ACC_BITS-1 -: `WAVETABLE_ADDR_BITS];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            phase <= 32'd0;
        else if (phase_load)
            phase <= 32'd0;
        else if (sample_tick)
            phase <= phase + fc;
    end

endmodule

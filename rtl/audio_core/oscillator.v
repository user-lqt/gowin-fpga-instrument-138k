//=============================================================================
// oscillator.v —— 单振荡器:相位累加器 + 波表查表
//
//   输出 latency 固定为 1 个 clk(波表同步读),不随音高变化,
//   因此不影响相位连续性,也不引入抖动。
//=============================================================================
`include "event_defs.vh"

module oscillator (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire               phase_load,
    input  wire [31:0]        fc,
    output wire signed [15:0] wave
);

    wire [`WAVETABLE_ADDR_BITS-1:0] addr;

    phase_acc u_phase_acc (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .phase_load  (phase_load),
        .fc          (fc),
        .phase       (),
        .addr        (addr)
    );

    wavetable u_wavetable (
        .clk  (clk),
        .addr (addr),
        .dout (wave)
    );

endmodule

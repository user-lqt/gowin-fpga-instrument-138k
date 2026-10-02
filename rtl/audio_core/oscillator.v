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
    input  wire [1:0]         instrument,
    output wire signed [15:0] wave
);

    wire [`WAVETABLE_ADDR_BITS-1:0] addr;
    wire signed [15:0] sine;
    reg signed [15:0] triangle, saw;
    reg [1:0] instrument_q;
    wire [9:0] triangle_ramp = addr[10] ? ~addr[9:0] : addr[9:0];
    wire signed [15:0] triangle_abs = $signed({1'b0, triangle_ramp, 5'b0});

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
        .dout (sine)
    );

    // Match the sine ROM's one-clock read latency for every waveform.
    always @(posedge clk) begin
        triangle <= addr[11] ? -triangle_abs : triangle_abs;
        saw <= $signed({~addr[11], addr[10:0], 4'b0});
        instrument_q <= instrument;
    end
    assign wave = instrument_q == 2'd1 ? triangle :
                  instrument_q == 2'd2 ? saw : sine;

endmodule

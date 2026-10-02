`timescale 1ns/1ps
// Functional clock-domain model only; PLL electrical lock is not simulated.
module clock_gen #(
    parameter IDIV_SEL=2, MDIV_SEL=29, ODIV0_SEL=59, ODIV1_SEL=7
) (
    input wire i_clk_in, i_rst_n,
    output wire o_clk_audio, o_clk_sys, o_pll_locked
);
    reg generated_clk=0;
    generate if (MDIV_SEL == 20) begin
        always #15 generated_clk=~generated_clk;
    end else begin
        always #40.6901 generated_clk=~generated_clk;
    end endgenerate
    assign o_clk_audio=generated_clk;
    assign o_clk_sys=generated_clk;
    assign o_pll_locked=i_rst_n;
endmodule

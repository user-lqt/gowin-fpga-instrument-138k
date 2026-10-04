// Simulation-only replacement for the Gowin PLL. Feed 12.288 MHz on i_clk_in.
module clock_gen (
    input wire i_clk_in, input wire i_rst_n,
    output wire o_clk_audio, output wire o_clk_sys, output wire o_pll_locked
);
    assign o_clk_audio = i_clk_in;
    assign o_clk_sys = i_clk_in;
    assign o_pll_locked = i_rst_n;
endmodule

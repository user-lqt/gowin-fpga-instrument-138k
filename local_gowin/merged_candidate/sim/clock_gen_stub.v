module clock_gen #(
    parameter integer IDIV_SEL = 1,
    parameter integer FBDIV_SEL = 20,
    parameter integer MDIV_SEL = 24,
    parameter integer ODIV0_SEL = 50,
    parameter integer ODIV1_SEL = 50
) (
    input wire i_clk_in,
    input wire i_rst_n,
    output wire o_clk_audio,
    output wire o_clk_sys,
    output wire o_pll_locked
);
    assign o_clk_audio = i_clk_in;
    assign o_clk_sys = i_clk_in;
    assign o_pll_locked = i_rst_n;
endmodule

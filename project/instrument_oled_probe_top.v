// Same instrument and pinout, with SSD1306 A5 forcing every pixel on.
// Use only to isolate display power/initialization from framebuffer content.
module instrument_oled_probe_top (
    input wire i_clk_in, i_rst_n,
    input wire [3:0] col_in,
    output wire [3:0] row_out,
    input wire enc_a, enc_b, enc_sw_n,
    inout wire oled_scl, oled_sda,
    output wire o_hp_bck, o_hp_ws, o_hp_din, o_pa_en, o_led, o_locked
);
    instrument_top #(.OLED_ALL_ON_DIAGNOSTIC(1)) instrument (
        .i_clk_in(i_clk_in), .i_rst_n(i_rst_n),
        .col_in(col_in), .row_out(row_out),
        .enc_a(enc_a), .enc_b(enc_b), .enc_sw_n(enc_sw_n),
        .oled_scl(oled_scl), .oled_sda(oled_sda),
        .o_hp_bck(o_hp_bck), .o_hp_ws(o_hp_ws), .o_hp_din(o_hp_din),
        .o_pa_en(o_pa_en), .o_led(o_led), .o_locked(o_locked)
    );
endmodule

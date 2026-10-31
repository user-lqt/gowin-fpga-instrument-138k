// Candidate wrapper only. The validated fixed-top project stays at 32 voices.
module instrument_64_top (
    input wire i_clk_in,i_rst_n,
    input wire [5:0] col_in,
    input wire enc_a,enc_b,enc_sw_n,
    input wire enc2_a,enc2_b,enc2_sw_n,
    input wire adc_miso,ble_uart_rx,k230_uart_rx,
    output wire ble_uart_tx,adc_cs_n,adc_sclk,adc_mosi,led_strip_din,
    output wire [7:0] row_out,
    output wire o_hp_bck,o_hp_ws,o_hp_din,o_pa_en,o_led,o_locked,
    output wire lcd_sc_clk,lcd_sc_hs,lcd_sc_vs,lcd_sc_de,
    output wire [5:0] lcd_r_out,lcd_g_out,lcd_b_out
);
    instrument_24_rgb_top #(.VOICE_COUNT(64)) u_instrument (
        .i_clk_in(i_clk_in),.i_rst_n(i_rst_n),.col_in(col_in),
        .enc_a(enc_a),.enc_b(enc_b),.enc_sw_n(enc_sw_n),
        .enc2_a(enc2_a),.enc2_b(enc2_b),.enc2_sw_n(enc2_sw_n),
        .adc_miso(adc_miso),.ble_uart_rx(ble_uart_rx),.ble_uart_tx(ble_uart_tx),
        .k230_uart_rx(k230_uart_rx),
        .adc_cs_n(adc_cs_n),.adc_sclk(adc_sclk),.adc_mosi(adc_mosi),
        .led_strip_din(led_strip_din),.row_out(row_out),
        .o_hp_bck(o_hp_bck),.o_hp_ws(o_hp_ws),.o_hp_din(o_hp_din),
        .o_pa_en(o_pa_en),.o_led(o_led),.o_locked(o_locked),
        .lcd_sc_clk(lcd_sc_clk),.lcd_sc_hs(lcd_sc_hs),.lcd_sc_vs(lcd_sc_vs),
        .lcd_sc_de(lcd_sc_de),.lcd_r_out(lcd_r_out),
        .lcd_g_out(lcd_g_out),.lcd_b_out(lcd_b_out)
    );
endmodule

// Isolated OLED probe: no keyboard scanner, DAC, or audio engine is active.
// SSD1306 A5 keeps every pixel on. Stop all bus traffic after initialization.
module oled_panel_probe_top (
    input wire i_clk_in, i_rst_n,
    inout wire oled_scl, oled_sda,
    output wire o_led, o_locked
);
    wire board_rst_n=~i_rst_n;
    wire clk_audio, clk_sys, pll_locked, rst_n;
    wire initialized, fault;
    clock_gen u_clock_gen (
        .i_clk_in(i_clk_in), .i_rst_n(board_rst_n),
        .o_clk_audio(clk_audio), .o_clk_sys(clk_sys),
        .o_pll_locked(pll_locked)
    );
    reset_sync #(.SYNC_STAGES(3)) u_reset_sync (
        .clk(clk_audio), .arst_n(board_rst_n & pll_locked), .rst_n(rst_n)
    );
    oled_display #(.ALL_ON_DIAGNOSTIC(1), .INIT_ONLY_DIAGNOSTIC(1)) u_oled (
        .clk(clk_audio), .rst_n(rst_n), .ui_dirty(1'b0),
        .ui_page(4'd0), .volume_value(16'd64), .instrument_value(16'd0),
        .active_voice_count(6'd0), .input_ready(1'b1),
        .audio_locked(pll_locked), .i2s_active(1'b0), .system_error(1'b0),
        .oled_scl(oled_scl), .oled_sda(oled_sda),
        .initialized(initialized), .fault(fault), .frame_done()
    );
    assign o_led=initialized;
    assign o_locked=pll_locked;
endmodule

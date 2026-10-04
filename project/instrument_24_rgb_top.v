`include "event_defs.vh"
// 24 dual-contact keys, four audio voices and an independent RGB pixel PLL.
// 25 us row dwell: 200 us velocity resolution, 8 ms press debounce,
// 12.8 ms release debounce. Velocity is captured before debounce.
module instrument_24_rgb_top #(
    parameter integer ROW_CYCLES = 307,
    parameter integer DEBOUNCE_FRAMES = 40,
    parameter integer DEFAULT_INSTRUMENT = 0
) (
    input wire i_clk_in, i_rst_n,
    input wire [5:0] col_in,
    input wire enc_a, enc_b, enc_sw_n,
    output wire [7:0] row_out,
    output wire o_hp_bck, o_hp_ws, o_hp_din, o_pa_en, o_led, o_locked,
    output wire lcd_sc_clk, lcd_sc_hs, lcd_sc_vs, lcd_sc_de,
    output wire [5:0] lcd_r_out, lcd_g_out, lcd_b_out
);
    wire board_rst_n = ~i_rst_n;
    localparam [15:0] INSTRUMENT_VALUE = DEFAULT_INSTRUMENT;
    wire clk_audio, pixel_clk, audio_pll_locked, pixel_pll_locked;
    wire rst_n, pixel_rst_n;
    clock_gen u_clock_gen (
        .i_clk_in(i_clk_in), .i_rst_n(board_rst_n), .o_clk_audio(clk_audio),
        .o_clk_sys(), .o_pll_locked(audio_pll_locked)
    );
    // 50 MHz * 20 / 30 = 33.333 MHz; VCO=1000 MHz, refresh=60.125 Hz.
    clock_gen #(.IDIV_SEL(1), .MDIV_SEL(20), .ODIV0_SEL(30), .ODIV1_SEL(30)) u_pixel_clock (
        .i_clk_in(i_clk_in), .i_rst_n(board_rst_n), .o_clk_audio(pixel_clk),
        .o_clk_sys(), .o_pll_locked(pixel_pll_locked)
    );
    // Audio must not be held in reset by an optional RGB panel clock.  A panel
    // PLL or LCD cable can fail independently while the onboard DAC remains
    // usable; keep the two clock domains' reset release independent.
    wire audio_reset_ready = board_rst_n && audio_pll_locked;
    wire pixel_reset_ready = board_rst_n && pixel_pll_locked;
    reset_sync u_audio_reset (.clk(clk_audio), .arst_n(audio_reset_ready), .rst_n(rst_n));
    reset_sync u_pixel_reset (.clk(pixel_clk), .arst_n(pixel_reset_ready), .rst_n(pixel_rst_n));

    wire sample_tick, bck, bck_en, frame_start;
    sample_scheduler #(.CLK_DIV_BCK(4), .CLK_DIV_SAMPLE(256)) u_scheduler (
        .clk_audio(clk_audio), .rst_n(rst_n), .sample_tick(sample_tick), .bck(bck), .bck_en(bck_en)
    );
    wire engine_ready, event_overflow, param_overflow, audio_locked, i2s_active, system_ready;
    wire [7:0] system_error;
    system_status u_status (
        .clk_audio(clk_audio), .board_rst_n(board_rst_n), .audio_rst_n(rst_n),
        .pll_locked(audio_pll_locked), .sample_tick(sample_tick), .frame_start(frame_start),
        .engine_ready(engine_ready), .event_overflow(event_overflow), .param_overflow(param_overflow),
        .audio_locked(audio_locked), .i2s_active(i2s_active),
        .system_ready(system_ready), .system_error(system_error)
    );
    wire keyboard_ready, event_valid;
    wire [1:0] event_type;
    wire [6:0] note_id;
    wire [7:0] velocity;
    wire [23:0] key_state;
    keyboard_24_input #(.ROW_CYCLES(ROW_CYCLES), .DEBOUNCE_FRAMES(DEBOUNCE_FRAMES),
        // 5004 includes saturation beyond 5003 scan frames (~1 second).
        .RELEASE_DEBOUNCE_FRAMES(64), .AB_MAX_FRAMES(5004),
        .BASE_NOTE(48), .EVENT_INTERVAL_CYCLES(256)) u_keyboard (
        .clk(clk_audio), .rst_n(rst_n && system_ready), .col_in(col_in), .row_out(row_out),
        .key_state(key_state), .input_ready(keyboard_ready), .event_valid(event_valid),
        .event_type(event_type), .note_id(note_id), .velocity(velocity)
    );
    wire encoder_ready;
    wire [15:0] volume_value, instrument_value, ui_param_value;
    wire encoder_param_valid;
    wire [3:0] encoder_param_id;
    wire [15:0] encoder_param_value;
    wire [3:0] ui_page;
    wire ui_dirty;
    wire diagnostic_step_up, diagnostic_step_down;
    encoder_control #(.FILTER_CYCLES(2500), .BUTTON_CYCLES(1000000),
        .REVERSE_DIR(0), .INSTRUMENT_COUNT(3)) u_encoder_control (
        .clk(clk_audio), .rst_n(rst_n && system_ready),
        .enc_a(enc_a), .enc_b(enc_b), .enc_sw_n(enc_sw_n),
        .input_ready(encoder_ready), .volume_value(volume_value),
        .instrument_value(instrument_value), .param_valid(encoder_param_valid),
        .param_id(encoder_param_id), .param_value(encoder_param_value),
        .ui_page(ui_page), .ui_param_value(ui_param_value), .ui_dirty(ui_dirty),
        .diagnostic_step_up(diagnostic_step_up), .diagnostic_step_down(diagnostic_step_down)
    );
    reg [2:0] enc_meta, enc_sync, enc_previous;
    reg [7:0] diagnostic_up, diagnostic_down, diagnostic_edges;
    // Independent synchronizer exposes the actual pads, even if decoding fails.
    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) begin
            enc_meta <= 3'b111; enc_sync <= 3'b111; enc_previous <= 3'b111;
            diagnostic_up <= 0; diagnostic_down <= 0; diagnostic_edges <= 0;
        end else begin
            enc_meta <= {enc_sw_n, enc_b, enc_a};
            enc_sync <= enc_meta;
            enc_previous <= enc_sync;
            if (system_ready && enc_sync[1:0] != enc_previous[1:0])
                diagnostic_edges <= diagnostic_edges + 1'b1;
            if (diagnostic_step_up) diagnostic_up <= diagnostic_up + 1'b1;
            if (diagnostic_step_down) diagnostic_down <= diagnostic_down + 1'b1;
        end
    end
    wire [31:0] diagnostic_status = {diagnostic_up, diagnostic_down,
        diagnostic_edges, ui_page, encoder_ready, enc_sync};
    wire param_valid = system_ready && encoder_param_valid;
    wire [3:0] param_id = encoder_param_id;
    wire [15:0] param_value = encoder_param_value;
    wire signed [23:0] audio_left, audio_right;
    wire [5:0] active_voice_count;
    wire audio_core_valid, overload_flag;
    audio_core u_audio_core (
        .clk(clk_audio), .rst_n(rst_n), .sample_tick(sample_tick),
        .event_valid(event_valid), .event_type(event_type), .note_id(note_id), .velocity(velocity),
        .param_valid(param_valid), .param_id(param_id), .param_value(param_value),
        .audio_core_valid(audio_core_valid), .audio_left(audio_left), .audio_right(audio_right),
        .active_voice_count(active_voice_count), .engine_ready(engine_ready),
        .overload_flag(overload_flag), .event_overflow(event_overflow), .param_overflow(param_overflow)
    );
    i2s_tx_official u_i2s_tx (
        .clk_audio(clk_audio), .rst_n(rst_n), .bck_in(bck), .bck_en(bck_en),
        .sample_l(audio_left[23:8]), .sample_r(audio_right[23:8]), .frame_start(frame_start),
        .o_bck(o_hp_bck), .o_ws(o_hp_ws), .o_din(o_hp_din)
    );
    wire lcd_frame_start;
    wire [87:0] display_status;
    lcd_status_bridge #(.WIDTH(88)) u_display_bridge (
        .source_clk(clk_audio), .source_rst_n(rst_n),
        .source_status({diagnostic_status, key_state, volume_value, instrument_value}),
        .pixel_clk(pixel_clk), .pixel_rst_n(pixel_rst_n), .frame_start(lcd_frame_start),
        .pixel_status(display_status)
    );
    rgb_lcd_800x480 #(.ENABLE_DIAGNOSTICS(1)) u_lcd (
        .pixel_clk(pixel_clk), .rst_n(pixel_rst_n), .key_state(display_status[55:32]),
        .volume_value(display_status[31:16]), .instrument_value(display_status[15:0]),
        .diagnostic_state(display_status[87:56]),
        .frame_start(lcd_frame_start), .sc_clk(lcd_sc_clk), .sc_hs(lcd_sc_hs),
        .sc_vs(lcd_sc_vs), .sc_de(lcd_sc_de), .r_out(lcd_r_out), .g_out(lcd_g_out), .b_out(lcd_b_out)
    );
    reg [23:0] heartbeat;
    always @(posedge clk_audio or negedge rst_n)
        if (!rst_n) heartbeat <= 0;
        else heartbeat <= heartbeat + 1'b1;
    assign o_led = (|system_error) ? 1'b1 : heartbeat[22];
    assign o_locked = audio_pll_locked;
    assign o_pa_en = 1'b0;
endmodule

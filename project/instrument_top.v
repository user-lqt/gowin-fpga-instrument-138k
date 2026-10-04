// Board integration of the keyboard/encoder, live synthesizer and onboard DAC.
// The fixed-tone synth_top remains a separate hardware baseline.
module instrument_top #(parameter OLED_ALL_ON_DIAGNOSTIC = 0) (
    input  wire       i_clk_in,
    input  wire       i_rst_n,
    input  wire [3:0] col_in,
    output wire [3:0] row_out,
    input  wire       enc_a,
    input  wire       enc_b,
    input  wire       enc_sw_n,
    inout  wire       oled_scl,
    inout  wire       oled_sda,
    output wire       o_hp_bck,
    output wire       o_hp_ws,
    output wire       o_hp_din,
    output wire       o_pa_en,
    output wire       o_led,
    output wire       o_locked
);
    wire board_rst_n = ~i_rst_n; // S2 is high while pressed.
    wire clk_audio, clk_sys, pll_locked, rst_n;
    clock_gen u_clock_gen (
        .i_clk_in(i_clk_in), .i_rst_n(board_rst_n),
        .o_clk_audio(clk_audio), .o_clk_sys(clk_sys),
        .o_pll_locked(pll_locked)
    );
    reset_sync #(.SYNC_STAGES(3)) u_reset_sync (
        .clk(clk_audio), .arst_n(board_rst_n & pll_locked), .rst_n(rst_n)
    );

    wire sample_tick, bck, bck_en, frame_start;
    sample_scheduler #(.CLK_DIV_BCK(4), .CLK_DIV_SAMPLE(256)) u_scheduler (
        .clk_audio(clk_audio), .rst_n(rst_n),
        .sample_tick(sample_tick), .bck(bck), .bck_en(bck_en)
    );

    wire event_valid, param_valid;
    wire [1:0] event_type;
    wire [6:0] note_id;
    wire [7:0] velocity;
    wire [3:0] param_id;
    wire [15:0] param_value;
    wire [5:0] active_voice_count;
    wire engine_ready, input_ready, audio_core_valid;
    wire overload_flag, event_overflow, param_overflow;
    wire audio_locked, i2s_active, system_ready;
    wire [7:0] system_error;
    wire signed [23:0] audio_left, audio_right;
    wire [3:0] ui_page;
    wire [15:0] volume_value, instrument_value;
    wire ui_dirty, oled_initialized, oled_fault;

    system_status u_status (
        .clk_audio(clk_audio), .board_rst_n(board_rst_n), .audio_rst_n(rst_n),
        .pll_locked(pll_locked), .sample_tick(sample_tick),
        .frame_start(frame_start), .engine_ready(engine_ready),
        .event_overflow(event_overflow), .param_overflow(param_overflow),
        .audio_locked(audio_locked), .i2s_active(i2s_active),
        .system_ready(system_ready), .system_error(system_error)
    );

    // 200 us/row: <=4.8 ms press and <=7.2 ms release scan/debounce latency.
    input_top #(.CLK_HZ(12288136), .ROW_CYCLES(2458),
        .DEBOUNCE_FRAMES(5), .RELEASE_FRAMES(8), .INSTRUMENT_COUNT(3)) u_input (
        .clk(clk_audio), .rst_n(rst_n), .system_ready(system_ready),
        .col_in(col_in), .row_out(row_out),
        .enc_a(enc_a), .enc_b(enc_b), .enc_sw_n(enc_sw_n),
        .active_voice_count(active_voice_count),
        .audio_locked(audio_locked), .i2s_active(i2s_active),
        .system_error(|system_error),
        .event_valid(event_valid), .event_type(event_type),
        .note_id(note_id), .velocity(velocity),
        .param_valid(param_valid), .param_id(param_id),
        .param_value(param_value),
        .key_state(), .sensor_value(), .input_ready(input_ready),
        .ui_page(ui_page), .ui_param_value(), .ui_dirty(ui_dirty),
        .volume_value(volume_value), .instrument_value(instrument_value)
    );

    oled_display #(.ALL_ON_DIAGNOSTIC(OLED_ALL_ON_DIAGNOSTIC)) u_oled (
        .clk(clk_audio), .rst_n(rst_n), .ui_dirty(ui_dirty),
        .ui_page(ui_page), .volume_value(volume_value), .instrument_value(instrument_value),
        .active_voice_count(active_voice_count), .input_ready(input_ready),
        .audio_locked(audio_locked), .i2s_active(i2s_active), .system_error(|system_error),
        .oled_scl(oled_scl), .oled_sda(oled_sda),
        .initialized(oled_initialized), .fault(oled_fault), .frame_done()
    );

    audio_core u_audio_core (
        .clk(clk_audio), .rst_n(rst_n), .sample_tick(sample_tick),
        .event_valid(event_valid), .event_type(event_type),
        .note_id(note_id), .velocity(velocity),
        .param_valid(param_valid), .param_id(param_id),
        .param_value(param_value),
        .audio_core_valid(audio_core_valid),
        .audio_left(audio_left), .audio_right(audio_right),
        .active_voice_count(active_voice_count), .engine_ready(engine_ready),
        .overload_flag(overload_flag),
        .event_overflow(event_overflow), .param_overflow(param_overflow)
    );

    // The proven onboard DAC format is 16 bits per channel at 48 kHz.
    // audio_core outputs stay stable between sample ticks. Its three-cycle
    // pipeline completes before the I2S serializer loads the next channel.
    i2s_tx_official u_i2s_tx (
        .clk_audio(clk_audio), .rst_n(rst_n),
        .bck_in(bck), .bck_en(bck_en),
        .sample_l(audio_left[23:8]), .sample_r(audio_right[23:8]),
        .frame_start(frame_start),
        .o_bck(o_hp_bck), .o_ws(o_hp_ws), .o_din(o_hp_din)
    );

    assign o_pa_en = 1'b0; // Official example: amplifier always enabled low.
    assign o_locked = pll_locked;
    reg [23:0] heartbeat;
    always @(posedge clk_audio or negedge rst_n)
        if (!rst_n) heartbeat <= 24'd0;
        else heartbeat <= heartbeat + 1'b1;
    // Per 1.37 s cycle: one pulse means OLED ready, two mean I2C failure.
    wire [3:0] led_slot=heartbeat[23:20];
    assign o_led = event_overflow ? 1'b1 :
        (oled_fault ? (led_slot==0 || led_slot==2) :
        (oled_initialized ? (led_slot==0) : heartbeat[22]));
endmodule

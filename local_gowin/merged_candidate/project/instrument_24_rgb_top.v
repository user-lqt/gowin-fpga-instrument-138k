`include "event_defs.vh"
// 24 dual-contact keys, 32 audio voices and an independent RGB pixel PLL.
// 25 us row dwell: 200 us velocity resolution, 8 ms press debounce,
// 12.8 ms release debounce. Velocity is captured before debounce.
module instrument_24_rgb_top #(
    parameter integer ROW_CYCLES = 307,
    parameter integer DEBOUNCE_FRAMES = 40,
    parameter integer DEFAULT_INSTRUMENT = 0,
    parameter integer FORMAL_CONTROLS = 1,
    parameter integer ENABLE_EXPRESSION = 1,
    parameter integer FSR_ZERO_LEVEL = 1,
    parameter integer FSR_FULL_SCALE = 899,
    parameter integer FSR_DEADBAND = 8,
    parameter integer ADC_SAMPLE_DIV = 4096
) (
    input wire i_clk_in, i_rst_n,
    input wire [5:0] col_in,
    input wire enc_a, enc_b, enc_sw_n,
    input wire enc2_a, enc2_b, enc2_sw_n,
    input wire adc_miso,
    input wire ble_uart_rx,
    input wire k230_uart_rx,
    output wire ble_uart_tx,
    output wire adc_cs_n,adc_sclk,adc_mosi,
    output wire led_strip_din,
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
    // PLL or LCD cable can fail independently while the external DAC remains
    // usable; keep the two clock domains' reset release independent.
    wire audio_reset_ready = board_rst_n && audio_pll_locked;
    wire pixel_reset_ready = board_rst_n && pixel_pll_locked;
    reset_sync u_audio_reset (.clk(clk_audio), .arst_n(audio_reset_ready), .rst_n(rst_n));
    reset_sync u_pixel_reset (.clk(pixel_clk), .arst_n(pixel_reset_ready), .rst_n(pixel_rst_n));

    wire sample_tick, bck, bck_en, frame_start;
    sample_scheduler #(.CLK_DIV_BCK(2), .CLK_DIV_SAMPLE(256)) u_scheduler (
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
    wire ble_event_valid, ble_frame_error;
    wire [1:0] ble_event_type;
    wire [6:0] ble_note_id;
    wire [7:0] ble_velocity;
    wire link_command_valid;
    wire [7:0] link_command,link_a,link_b;
    wire ble_song_valid;
    wire [1:0] ble_song_id;
    ble_uart_rx u_ble_uart (.clk(clk_audio),.rst_n(rst_n && system_ready),.uart_rx(ble_uart_rx),
        .event_valid(ble_event_valid),.event_type(ble_event_type),.note_id(ble_note_id),
        .velocity(ble_velocity),.frame_error(ble_frame_error),
        .song_valid(ble_song_valid),.song_id(ble_song_id),
        .command_valid(link_command_valid),.command(link_command),.argument_a(link_a),.argument_b(link_b));
    wire [23:0] key_state;
    wire [31:0] strike_debug;
    wire [15:0] strike_frames;
    keyboard_24_input #(.ROW_CYCLES(ROW_CYCLES), .DEBOUNCE_FRAMES(DEBOUNCE_FRAMES),
        // 5004 includes saturation beyond 5003 scan frames (~1 second).
        .RELEASE_DEBOUNCE_FRAMES(64), .AB_MAX_FRAMES(5004),
        .BASE_NOTE(60), .EVENT_INTERVAL_CYCLES(256)) u_keyboard (
        .clk(clk_audio), .rst_n(rst_n && system_ready), .col_in(col_in), .row_out(row_out),
        .key_state(key_state), .input_ready(keyboard_ready), .event_valid(event_valid),
        .event_type(event_type), .note_id(note_id), .velocity(velocity),
        .strike_debug(strike_debug),.strike_frames(strike_frames)
    );
    wire encoder_ready;
    wire [15:0] volume_value, instrument_value, ui_param_value;
    wire encoder_param_valid;
    wire [3:0] encoder_param_id;
    wire [15:0] encoder_param_value;
    wire [3:0] ui_page;
    wire ui_dirty;
    wire diagnostic_step_up, diagnostic_step_down;
    wire k230_param_valid, k230_frame_error;
    wire [3:0] k230_param_id;
    wire [15:0] k230_param_value;
    k230_control_rx u_k230_control (
        .clk(clk_audio), .rst_n(rst_n && system_ready), .uart_rx(k230_uart_rx),
        .param_valid(k230_param_valid), .param_id(k230_param_id),
        .param_value(k230_param_value), .frame_error(k230_frame_error)
    );
    encoder_control #(.FILTER_CYCLES(2500), .BUTTON_CYCLES(245760),
        .REVERSE_DIR(0), .INSTRUMENT_COUNT(3), .FORMAL_CONTROLS(FORMAL_CONTROLS),
        .DEFAULT_INSTRUMENT(DEFAULT_INSTRUMENT), .ENABLE_REMOTE(1)) u_encoder_control (
        .clk(clk_audio), .rst_n(rst_n && system_ready),
        .enc_a(enc_a), .enc_b(enc_b), .enc_sw_n(enc_sw_n),
        .input_ready(encoder_ready), .volume_value(volume_value),
        .instrument_value(instrument_value), .param_valid(encoder_param_valid),
        .param_id(encoder_param_id), .param_value(encoder_param_value),
        .ui_page(ui_page), .ui_param_value(ui_param_value), .ui_dirty(ui_dirty),
        .diagnostic_step_up(diagnostic_step_up), .diagnostic_step_down(diagnostic_step_down),
        .remote_valid(k230_param_valid), .remote_id(k230_param_id),
        .remote_value(k230_param_value)
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
    wire encoder_b_ready, encoder_b_param_valid;
    wire [2:0] encoder_b_menu;
    wire test_toggle,test_active,test_event_valid;
    wire [1:0] test_event_type;
    wire [6:0] test_note;
    wire [7:0] test_velocity;
    wire glide_enabled,song_select,lesson_toggle,lesson_running;
    wire [7:0] tempo;
    wire [9:0] lesson_position,lesson_total;
    wire [1:0] lesson_song;
    wire lesson_complete,lesson_unavailable;
    wire [1:0] local_song;
    wire [3:0] inspect_band;
    wire [7:0] user_score_length,user_score_key,user_score_duration,remote_tempo;
    wire [6:0] score_address;
    wire user_score_ready,rhythm_enabled,remote_tempo_valid,count_in,beat_flash;
    wire [2:0] timing_grade;
    wire [9:0] correct_count,miss_count;
    reg [7:0] lesson_tempo,previous_tempo;
    always @(posedge clk_audio or negedge rst_n) begin
        if(!rst_n) begin lesson_tempo<=120;previous_tempo<=120;end
        else begin
            previous_tempo<=tempo;
            if(remote_tempo_valid) lesson_tempo<=remote_tempo;
            else if(tempo!=previous_tempo) lesson_tempo<=tempo;
        end
    end
    wire [1:0] lesson_beat;
    wire [23:0] guide_keys;
    wire [6:0] glide_value,effect_value;
    wire [3:0] encoder_b_param_id;
    wire [15:0] encoder_b_param_value;
    encoder_b_control u_encoder_b (
        .clk(clk_audio),.rst_n(rst_n && system_ready),
        .enc_a(enc2_a),.enc_b(enc2_b),.enc_sw_n(enc2_sw_n),
        .input_ready(encoder_b_ready),.menu(encoder_b_menu),
        .glide_enabled(glide_enabled),.tempo(tempo),.song_select(song_select),.lesson_toggle(lesson_toggle),
        .test_toggle(test_toggle),
        .local_song(local_song),.inspect_band(inspect_band),
        .glide_value(glide_value),.effect_value(effect_value),
        .param_valid(encoder_b_param_valid),.param_id(encoder_b_param_id),
        .param_value(encoder_b_param_value)
    );
    lesson_guide u_lesson(.clk(clk_audio),.rst_n(rst_n && system_ready),
        .sample_tick(sample_tick),.rhythm_enabled(rhythm_enabled),.local_start(lesson_toggle),.local_song(local_song),
        .tempo(lesson_tempo),.user_length(user_score_length),.user_key(user_score_key),.user_duration(user_score_duration),
        .user_ready(user_score_ready),.score_address(score_address),.count_in(count_in),.beat_flash(beat_flash),
        .timing_grade(timing_grade),.correct_count(correct_count),.miss_count(miss_count),
        .song_mode(encoder_b_menu==3'd2),
        .select_valid(ble_song_valid || (link_command_valid && link_command==8'hB3 && link_a==0 && link_b==0)),
        .select_song(ble_song_valid ? ble_song_id : 2'd0),.keys(key_state),
        .running(lesson_running),.complete(lesson_complete),.unavailable(lesson_unavailable),
        .song(lesson_song),.total(lesson_total),.position(lesson_position),.beat(lesson_beat),.guide_keys(guide_keys));
    keyboard_led_strip u_led_strip (
        .clk(clk_audio), .rst_n(rst_n && system_ready),
        .lesson_running(encoder_b_menu==3'd2), .guide_keys(guide_keys),.beat_flash(beat_flash),
        .led_din(led_strip_din), .remaining()
    );
    wire param_valid,control_overflow;
    wire [3:0] param_id;
    wire [15:0] param_value;
    wire adc_sample_valid,adc_sample_error;
    wire [2:0] adc_sample_channel;
    wire [9:0] adc_ch0,adc_ch1,adc_ch2;
    mcp3008_sampler #(.CLK_DIV(12),.CHANNEL_COUNT(3),.SAMPLE_DIV(ADC_SAMPLE_DIV)) u_adc (
        .clk(clk_audio),.rst_n(rst_n && system_ready),.adc_miso(adc_miso),
        .adc_cs_n(adc_cs_n),.adc_sclk(adc_sclk),.adc_mosi(adc_mosi),.busy(),
        .sample_valid(adc_sample_valid),.sample_error(adc_sample_error),
        .sample_channel(adc_sample_channel),.ch0_data(adc_ch0),.ch1_data(adc_ch1),.ch2_data(adc_ch2));
    wire joystick_param_valid;
    wire [3:0] joystick_param_id;
    wire [15:0] joystick_param_value;
    joystick_control u_joystick (
        .clk(clk_audio),.rst_n(rst_n && system_ready),
        .sample_valid(adc_sample_valid),.sample_error(adc_sample_error),
        .sample_channel(adc_sample_channel),.ch1_x(adc_ch1),.ch2_y(adc_ch2),
        .param_valid(joystick_param_valid),.param_id(joystick_param_id),
        .param_value(joystick_param_value),.pitch_bend(),.modulation(),
        .filtered_x(),.filtered_y());
    wire fsr_param_valid;
    wire [3:0] fsr_param_id;
    wire [15:0] fsr_param_value;
    fsr_expression_control #(.ZERO_LEVEL(FSR_ZERO_LEVEL),.FULL_SCALE(FSR_FULL_SCALE),.DEADBAND(FSR_DEADBAND)) u_fsr (
        .clk(clk_audio),.rst_n(rst_n && system_ready),.sample_valid(adc_sample_valid),
        .sample_error(adc_sample_error),.sample_channel(adc_sample_channel),.ch0_data(adc_ch0),
        .param_valid(fsr_param_valid),.param_id(fsr_param_id),.param_value(fsr_param_value),
        .filtered_value(),.modulation_value(),.sensor_ready());
    encoder_param_queue u_control_queue (
        .clk(clk_audio),.rst_n(rst_n && system_ready),.sample_tick(sample_tick),
        .a_valid(encoder_param_valid),.a_id(encoder_param_id),.a_value(encoder_param_value),
        .b_valid(encoder_b_param_valid),.b_id(encoder_b_param_id),.b_value(encoder_b_param_value),
        .c_valid(joystick_param_valid && joystick_param_id==`PARAM_PITCH_BEND),
        .c_id(joystick_param_id),.c_value(joystick_param_value),
        .d_valid(fsr_param_valid),.d_id(fsr_param_id),.d_value(fsr_param_value),
        .valid(param_valid),.id(param_id),.value(param_value),.overflow(control_overflow)
    );
    wire signed [23:0] audio_left, audio_right;
    wire [5:0] active_voice_count;
    wire audio_core_valid, overload_flag;
    wire merged_event_valid,merge_overflow;
    wire [1:0] merged_event_type,mapped_type;
    wire [6:0] merged_note,mapped_note;
    wire [7:0] merged_velocity,mapped_velocity;
    wire mapped_valid,recording,dumping,record_overflow,reply_overflow;
    wire [9:0] record_count;
    instrument_link u_link(.clk(clk_audio),.rst_n(rst_n && system_ready),.sample_tick(sample_tick),
        .command_valid(link_command_valid),.command(link_command),.a(link_a),.b(link_b),.keys(key_state),
        .keyboard_valid(event_valid),.keyboard_type(event_type),.keyboard_note(note_id),.keyboard_velocity(velocity),
        .mapped_valid(mapped_valid),.mapped_type(mapped_type),.mapped_note(mapped_note),.mapped_velocity(mapped_velocity),
        .record_valid(merged_event_valid && !test_active),.record_type(merged_event_type),
        .record_note(merged_note),.record_velocity(merged_velocity),.lesson_running(lesson_running),.song_mode(encoder_b_menu==2),
        .score_address(score_address),.score_key(user_score_key),.score_duration(user_score_duration),
        .score_length(user_score_length),.score_ready(user_score_ready),.rhythm_enabled(rhythm_enabled),
        .remote_tempo(remote_tempo),.tempo_valid(remote_tempo_valid),.recording(recording),.record_count(record_count),
        .record_overflow(record_overflow),.dumping(dumping),.reply_overflow(reply_overflow),.tx(ble_uart_tx));
    performance_event_merge u_event_merge(.clk(clk_audio),.rst_n(rst_n && system_ready),
        .a_valid(test_event_valid),.a_type(test_event_type),.a_note(test_note),.a_velocity(test_velocity),
        .b_valid(ble_event_valid),.b_type(ble_event_type),.b_note(ble_note_id),.b_velocity(ble_velocity),
        .valid(merged_event_valid),.kind(merged_event_type),.note(merged_note),.velocity(merged_velocity),.overflow(merge_overflow));
    polyphony_test u_test(.clk(clk_audio),.rst_n(rst_n && system_ready),
        .sample_tick(sample_tick),.toggle(test_toggle),.keys(key_state),
        .keyboard_valid(mapped_valid),.keyboard_type(mapped_type),.keyboard_note(mapped_note),.keyboard_velocity(mapped_velocity),
        .active(test_active),.event_valid(test_event_valid),.event_type(test_event_type),.note_id(test_note),.velocity(test_velocity));
    audio_core #(.VOICE_COUNT(32),.ENABLE_EXPRESSION(ENABLE_EXPRESSION),
        .ENABLE_GUITAR(1),.RAM_BODY(1),.SHARE_VOICE_ARITHMETIC(1)) u_audio_core (
        .clk(clk_audio), .rst_n(rst_n), .sample_tick(sample_tick),
        .event_valid(merged_event_valid), .event_type(merged_event_type), .note_id(merged_note), .velocity(merged_velocity),
        // Keep half-scale headroom at full knob travel; the former /8 + /16
        // mapping capped output at 18.75% and made the instrument too quiet.
        .param_valid(param_valid), .param_id(param_id),
        // UI and engine share instrument IDs: piano=0, guitar=1, bell=2.
        .param_value(param_id == `PARAM_VOLUME ?
            {1'b0,param_value[15:1]} : param_value),
        .audio_core_valid(audio_core_valid), .audio_left(audio_left), .audio_right(audio_right),
        .active_voice_count(active_voice_count), .engine_ready(engine_ready),
        .overload_flag(overload_flag), .event_overflow(event_overflow), .param_overflow(param_overflow)
    );
    wire signed [23:0] effected_audio;
    audio_delay_fx u_fx(.clk(clk_audio),.rst_n(rst_n),.valid(audio_core_valid),
        .param_valid(param_valid),.param_id(param_id),.param_value(param_value),
        .audio_in(audio_left),.audio_out(effected_audio));
    i2s_tx_pcm5102a u_i2s_tx (
        .clk_audio(clk_audio), .rst_n(rst_n), .bck_in(bck), .bck_en(bck_en),
        .sample_l(effected_audio), .sample_r(effected_audio), .frame_start(frame_start),
        .o_bck(o_hp_bck), .o_ws(o_hp_ws), .o_din(o_hp_din)
    );
    wire lcd_frame_start;
    reg [7:0] last_velocity;
    reg [6:0] last_note;
    reg [4:0] last_key;
    wire [6:0] last_key_wide=note_id-7'd60;
    always @(posedge clk_audio or negedge rst_n) begin
        if(!rst_n) begin last_velocity<=0;last_note<=0;last_key<=0;end
        else begin
        if(event_valid && event_type==`EVENT_NOTE_ON) begin
            last_velocity<=velocity;last_key<=last_key_wide[4:0];
        end
        if(mapped_valid && mapped_type==`EVENT_NOTE_ON) last_note<=mapped_note;
        end
    end
    wire [7:0] display_errors=system_error | {reply_overflow,record_overflow,merge_overflow,1'b0,overload_flag,control_overflow,param_overflow,event_overflow};
    wire [40:0] strike_display;
    strike_display_formatter #(.ROW_CYCLES(ROW_CYCLES)) u_strike_display (
        .clk(clk_audio),.rst_n(rst_n),.debug_value(strike_debug),
        .frames(strike_frames),.display_value(strike_display));
    wire [209:0] display_status;
    lcd_status_bridge #(.WIDTH(210)) u_display_bridge (
        .source_clk(clk_audio), .source_rst_n(rst_n),
        .source_status({strike_display,lesson_song,lesson_complete,lesson_unavailable,lesson_total,lesson_position[9:5],
            encoder_b_menu[2],test_active,guide_keys,lesson_position[4:0],lesson_beat,lesson_running,1'b0,lesson_tempo,
            last_key,last_note,last_velocity,display_errors,active_voice_count,
            glide_enabled,encoder_b_menu[1:0],glide_value,effect_value,key_state,volume_value,instrument_value}),
        .pixel_clk(pixel_clk), .pixel_rst_n(pixel_rst_n), .frame_start(lcd_frame_start),
        .pixel_status(display_status)
    );
    wire [8:0] waveform_address;
    wire signed [15:0] waveform_minimum,waveform_maximum;
    wire waveform_ready;
    reg [1:0] waveform_valid;
    always @(posedge clk_audio or negedge rst_n)
        if(!rst_n) waveform_valid<=0;else waveform_valid<={waveform_valid[0],audio_core_valid};
    waveform_buffer u_waveform(.audio_clk(clk_audio),.audio_rst_n(rst_n),
        .valid(waveform_valid[1]),.sample(effected_audio[23:8]),
        .pixel_clk(pixel_clk),.pixel_rst_n(pixel_rst_n),.frame_start(lcd_frame_start),
        .read_address(waveform_address),.minimum(waveform_minimum),.maximum(waveform_maximum),.ready(waveform_ready));
    wire [127:0] spectrum_levels,display_spectrum;
    wire [3:0] visual_gain_shift;
    wire [48:0] display_features;
    wire [48:0] source_features={visual_gain_shift,inspect_band,correct_count,miss_count,
        record_count,local_song,user_score_ready,dumping,recording,rhythm_enabled,count_in,beat_flash,timing_grade};
    lcd_status_bridge #(.WIDTH(49)) u_feature_bridge(
        .source_clk(clk_audio),.source_rst_n(rst_n),.source_status(source_features),
        .pixel_clk(pixel_clk),.pixel_rst_n(pixel_rst_n),.frame_start(lcd_frame_start),.pixel_status(display_features));
    wire [13:0] xy_address;
    wire xy_hit,xy_ready;
    audio_visualizer u_visualizer(.audio_clk(clk_audio),.audio_rst_n(rst_n),
        .valid(waveform_valid[1]),.sample(effected_audio[23:8]),.spectrum(spectrum_levels),.gain_shift(visual_gain_shift),
        .pixel_clk(pixel_clk),.pixel_rst_n(pixel_rst_n),.frame_start(lcd_frame_start),
        .xy_address(xy_address),.xy_hit(xy_hit),.xy_ready(xy_ready));
    lcd_status_bridge #(.WIDTH(128)) u_spectrum_bridge(
        .source_clk(clk_audio),.source_rst_n(rst_n),.source_status(spectrum_levels),
        .pixel_clk(pixel_clk),.pixel_rst_n(pixel_rst_n),.frame_start(lcd_frame_start),
        .pixel_status(display_spectrum));
    instrument_dashboard u_lcd (
        .features(display_features),
        .spectrum(display_spectrum),.xy_address(xy_address),.xy_hit(xy_hit),.xy_ready(xy_ready),
        .pixel_clk(pixel_clk), .rst_n(pixel_rst_n), .status(display_status),
        .wave_address(waveform_address),.wave_min(waveform_minimum),.wave_max(waveform_maximum),.wave_ready(waveform_ready),
        .frame_start(lcd_frame_start), .sc_clk(lcd_sc_clk), .sc_hs(lcd_sc_hs),
        .sc_vs(lcd_sc_vs), .sc_de(lcd_sc_de), .r_out(lcd_r_out), .g_out(lcd_g_out), .b_out(lcd_b_out)
    );
    reg [23:0] heartbeat;
    always @(posedge clk_audio or negedge rst_n)
        if (!rst_n) heartbeat <= 0;
        else heartbeat <= heartbeat + 1'b1;
    assign o_led = ((|system_error) || control_overflow) ? 1'b1 : heartbeat[22];
    assign o_locked = audio_pll_locked;
    assign o_pa_en = 1'b0;
endmodule

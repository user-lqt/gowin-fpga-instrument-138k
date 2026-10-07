`include "event_defs.vh"
// 24 keys, 32 voices, piano/bell only, FSR vibrato and an RGB pixel PLL.
// 25 us row dwell: 200 us velocity resolution, 8 ms press debounce,
// 12.8 ms release debounce. Velocity is captured before debounce.
module instrument_24_rgb_top #(
    parameter integer ROW_CYCLES = 307,
    parameter integer DEBOUNCE_FRAMES = 40,
    parameter integer DEFAULT_INSTRUMENT = 0,
    parameter integer FORMAL_CONTROLS = 1,
    // CH0 to GND measured at 2 mV released and 2.9 V under heavy pressure.
    parameter integer FSR_ZERO_LEVEL = 1,
    parameter integer FSR_FULL_SCALE = 899,
    parameter integer FSR_DEADBAND = 8,
    parameter integer ADC_SAMPLE_DIV = 4096,
    parameter integer ENABLE_JOYSTICK = 0,
    parameter integer MASTER_GAIN_SHIFT = 5 // 1/32 headroom for the 32-voice sum.
) (
    input wire i_clk_in, i_rst_n,
    input wire [5:0] col_in,
    input wire enc_a, enc_b, enc_sw_n,
    input wire enc2_a, enc2_b, enc2_sw_n,
    input wire adc_miso,
    output wire [7:0] row_out,
    output wire o_hp_bck, o_hp_ws, o_hp_din, o_pa_en, o_led, o_locked,
    output wire adc_cs_n, adc_sclk, adc_mosi,
    output wire lcd_sc_clk, lcd_sc_hs, lcd_sc_vs, lcd_sc_de,
    output wire [5:0] lcd_r_out, lcd_g_out, lcd_b_out
);
    wire board_rst_n = ~i_rst_n;
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
    encoder_control #(.FILTER_CYCLES(2500), .BUTTON_CYCLES(245760),
        .REVERSE_DIR(0), .INSTRUMENT_COUNT(2), .FORMAL_CONTROLS(FORMAL_CONTROLS),
        .DEFAULT_INSTRUMENT(DEFAULT_INSTRUMENT==0 ? 0 : 1)) u_encoder_control (
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
    wire encoder_b_ready, encoder_b_menu, encoder_b_param_valid;
    wire [6:0] glide_value,effect_value;
    wire [3:0] encoder_b_param_id;
    wire [15:0] encoder_b_param_value;
    encoder_b_control u_encoder_b (
        .clk(clk_audio),.rst_n(rst_n && system_ready),
        .enc_a(enc2_a),.enc_b(enc2_b),.enc_sw_n(enc2_sw_n),
        .input_ready(encoder_b_ready),.menu(encoder_b_menu),
        .glide_value(glide_value),.effect_value(effect_value),
        .param_valid(encoder_b_param_valid),.param_id(encoder_b_param_id),
        .param_value(encoder_b_param_value)
    );
    wire param_valid,control_overflow;
    wire [3:0] param_id;
    wire [15:0] param_value;
    wire adc_busy,adc_sample_valid,adc_sample_error;
    wire [2:0] adc_sample_channel;
    wire [9:0] adc_ch0,adc_ch1,adc_ch2;
    mcp3008_sampler #(.CLK_DIV(12),.SAMPLE_DIV(ADC_SAMPLE_DIV),
        .CHANNEL_COUNT(ENABLE_JOYSTICK != 0 ? 3 : 1)) u_mcp3008_sampler (
        .clk(clk_audio),.rst_n(rst_n && system_ready),.adc_miso(adc_miso),
        .adc_cs_n(adc_cs_n),.adc_sclk(adc_sclk),.adc_mosi(adc_mosi),.busy(adc_busy),
        .sample_valid(adc_sample_valid),.sample_error(adc_sample_error),
        .sample_channel(adc_sample_channel),
        .ch0_data(adc_ch0),.ch1_data(adc_ch1),.ch2_data(adc_ch2)
    );
    wire joystick_param_valid;
    wire [3:0] joystick_param_id;
    wire [15:0] joystick_param_value;
    wire signed [15:0] joystick_pitch_bend;
    wire [15:0] joystick_modulation;
    joystick_control u_joystick_control (
        .clk(clk_audio),.rst_n(rst_n && system_ready),.sample_valid(adc_sample_valid),
        .sample_channel(adc_sample_channel),.ch1_x(adc_ch1),.ch2_y(adc_ch2),
        .param_valid(joystick_param_valid),.param_id(joystick_param_id),
        .param_value(joystick_param_value),.pitch_bend(joystick_pitch_bend),
        .modulation(joystick_modulation),.filtered_x(),.filtered_y()
    );
    wire fsr_param_valid, fsr_sensor_ready;
    wire [3:0] fsr_param_id;
    wire [15:0] fsr_param_value, fsr_modulation;
    wire [9:0] fsr_filtered;
    fsr_expression_control #(
        .ZERO_LEVEL(FSR_ZERO_LEVEL), .FULL_SCALE(FSR_FULL_SCALE),
        .DEADBAND(FSR_DEADBAND)
    ) u_fsr_control (
        .clk(clk_audio), .rst_n(rst_n && system_ready),
        .sample_valid(adc_sample_valid), .sample_error(adc_sample_error),
        .sample_channel(adc_sample_channel),
        .ch0_data(adc_ch0), .param_valid(fsr_param_valid),
        .param_id(fsr_param_id), .param_value(fsr_param_value),
        .filtered_value(fsr_filtered), .modulation_value(fsr_modulation),
        .sensor_ready(fsr_sensor_ready)
    );
    encoder_param_queue u_control_queue (
        .clk(clk_audio),.rst_n(rst_n && system_ready),.sample_tick(sample_tick),
        .a_valid(encoder_param_valid),.a_id(encoder_param_id),.a_value(encoder_param_value),
        .b_valid(encoder_b_param_valid),.b_id(encoder_b_param_id),.b_value(encoder_b_param_value),
        // FSR owns modulation; Y-axis events must not overwrite its depth.
        .c_valid(ENABLE_JOYSTICK != 0 && joystick_param_valid &&
            joystick_param_id==`PARAM_PITCH_BEND),
        .c_id(joystick_param_id),.c_value(joystick_param_value),
        .d_valid(fsr_param_valid),.d_id(fsr_param_id),.d_value(fsr_param_value),
        .valid(param_valid),.id(param_id),.value(param_value),.overflow(control_overflow)
    );
    wire signed [23:0] audio_left, audio_right;
    wire [5:0] active_voice_count;
    wire audio_core_valid, overload_flag;
    // UI slots 0/1 are piano/bell; retain audio IDs 0/2 for compatibility.
    wire [15:0] audio_param_value = param_id==`PARAM_VOLUME ?
        param_value >> MASTER_GAIN_SHIFT : param_id==`PARAM_INSTRUMENT ?
        (param_value==0 ? 16'd0 : 16'd2) : param_value;
    audio_core #(.VOICE_COUNT(32), .ENABLE_EXPRESSION(1), .ENABLE_GUITAR(0)) u_audio_core (
        .clk(clk_audio), .rst_n(rst_n), .sample_tick(sample_tick),
        .event_valid(event_valid), .event_type(event_type), .note_id(note_id), .velocity(velocity),
        .param_valid(param_valid), .param_id(param_id), .param_value(audio_param_value),
        .audio_core_valid(audio_core_valid), .audio_left(audio_left), .audio_right(audio_right),
        .active_voice_count(active_voice_count), .engine_ready(engine_ready),
        .overload_flag(overload_flag), .event_overflow(event_overflow), .param_overflow(param_overflow)
    );
    wire signed [15:0] dac_frame_left, dac_frame_right;
    audio_frame_buffer u_audio_frame_buffer (
        .clk(clk_audio), .rst_n(rst_n), .pcm_valid(audio_core_valid),
        .frame_start(frame_start), .pcm_left(audio_left), .pcm_right(audio_right),
        .frame_left(dac_frame_left), .frame_right(dac_frame_right)
    );
    i2s_tx_official u_i2s_tx (
        .clk_audio(clk_audio), .rst_n(rst_n), .bck_in(bck), .bck_en(bck_en),
        .sample_l(dac_frame_left), .sample_r(dac_frame_right), .frame_start(frame_start),
        .o_bck(o_hp_bck), .o_ws(o_hp_ws), .o_din(o_hp_din)
    );
    wire lcd_frame_start;
    // Pipeline mapping, percent scaling and BCD conversion separately so LCD
    // telemetry does not create a filter-to-display critical path.
    function [15:0] decimal_digits;
        input [9:0] binary_value;
        reg [15:0] bcd;
        integer digit, bit_index;
        begin
            bcd = 0;
            for (bit_index=9; bit_index>=0; bit_index=bit_index-1) begin
                for (digit=0; digit<4; digit=digit+1)
                    if (bcd[digit*4+:4] >= 5)
                        bcd[digit*4+:4] = bcd[digit*4+:4] + 4'd3;
                bcd = {bcd[14:0], binary_value[bit_index]};
            end
            decimal_digits = bcd;
        end
    endfunction
    reg [15:0] fsr_display_modulation;
    reg [31:0] fsr_percent_scaled;
    reg [9:0] fsr_percent;
    reg [9:0] adc_snapshot, adc_scaled, adc_percent;
    reg ready_snapshot, ready_scaled, ready_percent, fsr_display_ready;
    reg [15:0] adc_digits, fsr_digits;
    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) begin
            fsr_display_modulation <= 0;
            fsr_percent_scaled <= 0;
            fsr_percent <= 0;
            adc_snapshot <= 0;
            adc_scaled <= 0;
            adc_percent <= 0;
            ready_snapshot <= 0;
            ready_scaled <= 0;
            ready_percent <= 0;
            fsr_display_ready <= 0;
            adc_digits <= 0;
            fsr_digits <= 0;
        end else begin
            fsr_display_modulation <= fsr_modulation;
            adc_snapshot <= adc_ch0;
            ready_snapshot <= fsr_sensor_ready;
            fsr_percent_scaled <= fsr_display_modulation * 32'd100 + 32'd32767;
            adc_scaled <= adc_snapshot;
            ready_scaled <= ready_snapshot;
            fsr_percent <= fsr_percent_scaled / 32'd65535;
            adc_percent <= adc_scaled;
            ready_percent <= ready_scaled;
            adc_digits <= decimal_digits(adc_percent);
            fsr_digits <= decimal_digits(fsr_percent);
            fsr_display_ready <= ready_percent;
        end
    end
    wire [131:0] display_status;
    lcd_status_bridge #(.WIDTH(132)) u_display_bridge (
        .source_clk(clk_audio), .source_rst_n(rst_n),
        .source_status({fsr_display_ready,fsr_digits[11:0],adc_digits,
            encoder_b_menu,glide_value,effect_value,diagnostic_status, key_state, volume_value, instrument_value}),
        .pixel_clk(pixel_clk), .pixel_rst_n(pixel_rst_n), .frame_start(lcd_frame_start),
        .pixel_status(display_status)
    );
    rgb_lcd_800x480 #(.ENABLE_DIAGNOSTICS(FORMAL_CONTROLS == 0),
        .ENABLE_B_MENU(1),.ENABLE_FSR_STATUS(1)) u_lcd (
        .pixel_clk(pixel_clk), .rst_n(pixel_rst_n), .key_state(display_status[55:32]),
        .volume_value(display_status[31:16]), .instrument_value(display_status[15:0]),
        .diagnostic_state(display_status[87:56]),
        .control_menu(display_status[102]),.glide_value(display_status[101:95]),
        .effect_value(display_status[94:88]),
        .adc_digits(display_status[118:103]),.vibrato_digits(display_status[130:119]),
        .sensor_ready(display_status[131]),
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

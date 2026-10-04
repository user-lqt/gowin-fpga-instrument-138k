`timescale 1ns/1ps

// Integration check: B stays in reset until C enables it, then becomes ready.
module tb_startup_with_input;
    reg clk = 0;
    always #5 clk = ~clk;

    reg board_rst_n = 0;
    reg audio_rst_n = 0;
    reg pll_locked = 0;
    reg sample_tick = 0;
    reg frame_start = 0;
    reg engine_ready = 0;
    reg event_overflow = 0;
    reg param_overflow = 0;
    wire audio_locked, i2s_active, system_ready;
    wire [7:0] system_error;
    wire input_ready;
    wire [3:0] row_out;
    wire [15:0] key_state, sensor_value, ui_param_value;
    wire [3:0] ui_page;
    wire ui_dirty;
    wire [15:0] volume_value, instrument_value;
    wire event_valid, param_valid;
    wire [1:0] event_type;
    wire [6:0] note_id;
    wire [7:0] velocity;
    wire [3:0] param_id;
    wire [15:0] param_value;

    system_status status (
        .clk_audio(clk), .board_rst_n(board_rst_n), .audio_rst_n(audio_rst_n),
        .pll_locked(pll_locked), .sample_tick(sample_tick),
        .frame_start(frame_start), .engine_ready(engine_ready),
        .event_overflow(event_overflow), .param_overflow(param_overflow),
        .audio_locked(audio_locked), .i2s_active(i2s_active),
        .system_ready(system_ready),
        .system_error(system_error)
    );

    input_top #(
        .CLK_HZ(120000), .ROW_CYCLES(4), .DEBOUNCE_FRAMES(1),
        .FILTER_CYCLES(3), .BUTTON_CYCLES(3)
    ) input_unit (
        .clk(clk), .rst_n(audio_rst_n), .system_ready(system_ready),
        .col_in(4'b1111), .row_out(row_out),
        .enc_a(1'b1), .enc_b(1'b1), .enc_sw_n(1'b1),
        .active_voice_count(6'd0), .audio_locked(audio_locked),
        .i2s_active(i2s_active), .system_error(|system_error),
        .event_valid(event_valid), .event_type(event_type),
        .note_id(note_id), .velocity(velocity),
        .param_valid(param_valid), .param_id(param_id),
        .param_value(param_value), .key_state(key_state),
        .sensor_value(sensor_value), .input_ready(input_ready),
        .ui_page(ui_page), .ui_param_value(ui_param_value),
        .ui_dirty(ui_dirty), .volume_value(volume_value),
        .instrument_value(instrument_value)
    );

    initial begin
        repeat (4) @(negedge clk);
        board_rst_n = 1;
        pll_locked = 1;
        audio_rst_n = 1;
        repeat (4) @(negedge clk);
        if (system_ready || input_ready) $fatal(1, "B started before engine");
        engine_ready = 1;
        sample_tick = 1;
        @(negedge clk);
        sample_tick = 0;
        frame_start = 1;
        @(negedge clk);
        frame_start = 0;
        #1;
        if (!system_ready || input_ready) $fatal(1, "C must enable B first");
        wait (input_ready);
        @(negedge clk);
        if (!system_ready) $fatal(1, "C ready lost when B became ready");
        event_overflow = 1;
        #1;
        if (system_ready || !system_error[7]) $fatal(1, "event fault not propagated");
        repeat (3) @(negedge clk);
        if (input_ready) $fatal(1, "B must return to reset after event fault");
        $display("PASS C/B startup and event-fault shutdown");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "C/B startup timeout");
    end
endmodule

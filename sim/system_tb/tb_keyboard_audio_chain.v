`timescale 1ns/1ps
`include "event_defs.vh"

// C integration regression against the current A and B branch snapshots.
// Uses the actual /256 sample scheduler and the onboard DAC's 16-bit I2S path.
module tb_keyboard_audio_chain;
    reg clk_audio = 0;
    always #40.6901 clk_audio = ~clk_audio;
    reg rst_n = 0;
    reg [15:0] pressed = 0;
    wire [3:0] row_out;
    wire [3:0] col_in = (row_out[0] === 1'b0) ? ~pressed[3:0] :
                        (row_out[1] === 1'b0) ? ~pressed[7:4] :
                        (row_out[2] === 1'b0) ? ~pressed[11:8] :
                        (row_out[3] === 1'b0) ? ~pressed[15:12] : 4'b1111;
    wire sample_tick, bck, bck_en, frame_start;
    wire hp_bck, hp_ws, hp_din;
    wire event_valid, param_valid, input_ready, audio_core_valid;
    wire [1:0] event_type;
    wire [6:0] note_id;
    wire [7:0] velocity;
    wire [3:0] param_id;
    wire [15:0] param_value;
    wire [15:0] key_state, sensor_value, ui_param_value;
    wire [3:0] ui_page;
    wire ui_dirty;
    wire [15:0] volume_value, instrument_value;
    wire signed [23:0] audio_left, audio_right;
    wire [5:0] active_voice_count;
    wire engine_ready, overload_flag;
    wire event_overflow, param_overflow;
    wire audio_locked, i2s_active, system_ready;
    wire [7:0] system_error;
    integer event_on_count=0, event_off_count=0, all_on_count=0, all_off_count=0, param_count=0;
    integer max_event_queue=0;
    reg [6:0] last_on_note=0;
    reg [15:0] seen_on=0, seen_off=0;
    integer active_samples=0, nonzero_samples=0, silent_samples=0;
    integer ws_edges=0, bck_edges=0;
    reg last_ws=0, last_bck=0;

    sample_scheduler #(.CLK_DIV_BCK(4), .CLK_DIV_SAMPLE(256)) scheduler (
        .clk_audio(clk_audio), .rst_n(rst_n), .sample_tick(sample_tick),
        .bck(bck), .bck_en(bck_en)
    );
    system_status status (
        .clk_audio(clk_audio), .board_rst_n(rst_n), .audio_rst_n(rst_n),
        .pll_locked(1'b1), .sample_tick(sample_tick),
        .frame_start(frame_start), .engine_ready(engine_ready),
        .event_overflow(event_overflow), .param_overflow(param_overflow),
        .audio_locked(audio_locked), .i2s_active(i2s_active),
        .system_ready(system_ready), .system_error(system_error)
    );
    input_top #(.CLK_HZ(12288000)) input_unit (
        .clk(clk_audio), .rst_n(rst_n), .system_ready(system_ready),
        .col_in(col_in), .row_out(row_out),
        .enc_a(1'b1), .enc_b(1'b1), .enc_sw_n(1'b1),
        .active_voice_count(active_voice_count), .audio_locked(audio_locked),
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
    audio_core core (
        .clk(clk_audio), .rst_n(rst_n), .sample_tick(sample_tick),
        .event_valid(event_valid), .event_type(event_type),
        .note_id(note_id), .velocity(velocity),
        .param_valid(param_valid), .param_id(param_id),
        .param_value(param_value),
        .audio_core_valid(audio_core_valid), .audio_left(audio_left),
        .audio_right(audio_right), .active_voice_count(active_voice_count),
        .engine_ready(engine_ready), .overload_flag(overload_flag),
        .event_overflow(event_overflow), .param_overflow(param_overflow)
    );
    i2s_tx_official tx (
        .clk_audio(clk_audio), .rst_n(rst_n), .bck_in(bck), .bck_en(bck_en),
        .sample_l(audio_left[23:8]), .sample_r(audio_right[23:8]),
        .frame_start(frame_start), .o_bck(hp_bck), .o_ws(hp_ws), .o_din(hp_din)
    );

    always @(posedge clk_audio) begin
        if (rst_n) begin
            if (event_valid && event_type == `EVENT_NOTE_ON && note_id == 60)
                event_on_count = event_on_count + 1;
            if (event_valid && event_type == `EVENT_NOTE_OFF && note_id == 60)
                event_off_count = event_off_count + 1;
            if (event_valid && event_type == `EVENT_NOTE_ON) begin
                all_on_count = all_on_count + 1;
                if (note_id >= 60 && note_id <= 75) seen_on[note_id-60] = 1'b1;
                last_on_note = note_id;
            end
            if (event_valid && event_type == `EVENT_NOTE_OFF) begin
                all_off_count = all_off_count + 1;
                if (note_id >= 60 && note_id <= 75) seen_off[note_id-60] = 1'b1;
            end
            if (core.ev_count > max_event_queue)
                max_event_queue = core.ev_count;
            if (param_valid) param_count = param_count + 1;
            if (audio_core_valid) begin
                if (active_voice_count != 0) begin
                    active_samples = active_samples + 1;
                    if (audio_left != 0 && audio_right != 0)
                        nonzero_samples = nonzero_samples + 1;
                end else if (audio_left == 0 && audio_right == 0)
                    silent_samples = silent_samples + 1;
            end
            if (hp_ws != last_ws) ws_edges = ws_edges + 1;
            if (hp_bck != last_bck) bck_edges = bck_edges + 1;
            last_ws = hp_ws;
            last_bck = hp_bck;
        end
    end

    initial begin
        repeat (5) @(negedge clk_audio);
        rst_n = 1;
        wait (system_ready && input_ready);
        repeat (5) @(negedge clk_audio);
        if (param_count < 2 || core.volume != 16'd33026)
            $fatal(1, "startup parameters failed: count=%0d volume=%0d",
                   param_count, core.volume);
        if (event_on_count || event_off_count || active_voice_count)
            $fatal(1, "unexpected event at startup");

        pressed[0] = 1;
        wait (event_on_count == 1);
        repeat (300) @(posedge sample_tick);
        if (active_voice_count != 1 || nonzero_samples < 200)
            $fatal(1, "key press did not generate sustained sound: samples=%0d", nonzero_samples);
        if (ws_edges < 10 || bck_edges < 300)
            $fatal(1, "I2S clocks did not run");

        @(negedge clk_audio); pressed[0] = 0;
        wait (event_off_count == 1);
        repeat (4805) @(posedge sample_tick);
        if (active_voice_count != 0 || audio_left != 0 || audio_right != 0)
            $fatal(1, "key release did not silence audio");
        if (event_on_count != 1 || event_off_count != 1)
            $fatal(1, "duplicate note event");

        @(negedge clk_audio); pressed = 16'hffff;
        wait (all_on_count == 17);
        repeat (20) @(posedge sample_tick);
        if (event_overflow || core.ev_count != 0 || active_voice_count != 4 || seen_on != 16'hffff)
            $fatal(1, "16-key press burst lost or reordered: queue=%0d last=%0d",
                   core.ev_count, last_on_note);
        @(negedge clk_audio); pressed = 0;
        wait (all_off_count == 17);
        repeat (4805) @(posedge sample_tick);
        if (event_overflow || core.ev_count != 0 || active_voice_count != 0 || seen_off != 16'hffff)
            $fatal(1, "16-key release burst lost or left voice active: count=%0d last=%0d",
                   active_voice_count, last_on_note);
        // Scan/sample phase may pop one event while the 16-key burst arrives.
        if (max_event_queue < 15)
            $fatal(1, "stress case did not exercise near-full event queue: max=%0d", max_event_queue);
        $display("PASS real B keyboard -> A audio -> C I2S: params=%0d notes=%0d/%0d max_queue=%0d nonzero_samples=%0d ws_edges=%0d",
                 param_count, all_on_count, all_off_count, max_event_queue,
                 nonzero_samples, ws_edges);
        $finish;
    end
    initial begin
        #250000000;
        $fatal(1, "keyboard to audio integration timed out");
    end
endmodule

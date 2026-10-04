// Diagnostic only: hold A4 through the A2 core, without external inputs.
// This isolates the synthesizer/I2S path from keyboard and encoder wiring.
module audio_a2_probe_top (
    input wire i_clk_in, i_rst_n,
    output wire o_hp_bck, o_hp_ws, o_hp_din, o_pa_en, o_led, o_locked
);
    wire board_rst_n = ~i_rst_n;
    wire clk_audio, clk_sys, pll_locked, rst_n;
    clock_gen u_clock_gen (
        .i_clk_in(i_clk_in), .i_rst_n(board_rst_n),
        .o_clk_audio(clk_audio), .o_clk_sys(clk_sys), .o_pll_locked(pll_locked)
    );
    reset_sync #(.SYNC_STAGES(3)) u_reset_sync (
        .clk(clk_audio), .arst_n(board_rst_n & pll_locked), .rst_n(rst_n)
    );
    wire sample_tick, bck, bck_en, frame_start;
    sample_scheduler #(.CLK_DIV_BCK(4), .CLK_DIV_SAMPLE(256)) u_scheduler (
        .clk_audio(clk_audio), .rst_n(rst_n),
        .sample_tick(sample_tick), .bck(bck), .bck_en(bck_en)
    );
    wire engine_ready, valid, overload, event_overflow, param_overflow;
    wire [5:0] voice_count;
    wire signed [23:0] audio_l, audio_r;
    reg sent;
    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) sent <= 1'b0;
        else if (engine_ready) sent <= 1'b1;
    end
    audio_core u_audio_core (
        .clk(clk_audio), .rst_n(rst_n), .sample_tick(sample_tick),
        .event_valid(engine_ready && !sent), .event_type(2'd1),
        .note_id(7'd69), .velocity(8'd127),
        .param_valid(1'b0), .param_id(4'd0), .param_value(16'd0),
        .audio_core_valid(valid), .audio_left(audio_l), .audio_right(audio_r),
        .active_voice_count(voice_count), .engine_ready(engine_ready),
        .overload_flag(overload), .event_overflow(event_overflow),
        .param_overflow(param_overflow)
    );
    i2s_tx_official u_i2s_tx (
        .clk_audio(clk_audio), .rst_n(rst_n), .bck_in(bck), .bck_en(bck_en),
        .sample_l(audio_l[23:8]), .sample_r(audio_r[23:8]),
        .frame_start(frame_start),
        .o_bck(o_hp_bck), .o_ws(o_hp_ws), .o_din(o_hp_din)
    );
    assign o_pa_en = 1'b0;
    assign o_locked = pll_locked;
    assign o_led = event_overflow | overload;
endmodule

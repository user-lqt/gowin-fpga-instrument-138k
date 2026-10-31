`include "status_defs.vh"

// C-side readiness and input-queue fault reporting, all in clk_audio domain.
module system_status (
    input  wire       clk_audio,
    input  wire       board_rst_n,
    input  wire       audio_rst_n,
    input  wire       pll_locked,
    input  wire       sample_tick,
    input  wire       frame_start,
    input  wire       engine_ready,
    input  wire       event_overflow,
    input  wire       param_overflow,
    output wire       audio_locked,
    output wire       i2s_active,
    output wire       system_ready,
    output wire [7:0] system_error
);
    reg seen_sample_tick;
    reg seen_frame_start;

    always @(posedge clk_audio or negedge audio_rst_n) begin
        if (!audio_rst_n) begin
            seen_sample_tick <= 1'b0;
            seen_frame_start <= 1'b0;
        end else begin
            if (sample_tick) seen_sample_tick <= 1'b1;
            if (frame_start) seen_frame_start <= 1'b1;
        end
    end

    assign i2s_active = audio_rst_n && pll_locked && seen_frame_start;
    assign audio_locked = i2s_active && seen_sample_tick;
    // B starts only after system_ready. input_ready must not feed this equation.
    assign system_ready = audio_locked && engine_ready && !event_overflow;

    assign system_error = board_rst_n ?
        ((!pll_locked ? `ERR_CLK_UNLOCKED : `ERR_NONE) |
         ((event_overflow || param_overflow) ? `ERR_INPUT_QUEUE_OVERFLOW : `ERR_NONE)) :
        `ERR_NONE;
endmodule

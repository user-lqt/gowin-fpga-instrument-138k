// The core can finish between the DAC's two channel loads. Commit PCM only
// at a frame boundary so both channel slots always use the same audio frame.
module audio_frame_buffer (
    input wire clk, rst_n,
    input wire pcm_valid, frame_start,
    input wire signed [23:0] pcm_left, pcm_right,
    output reg signed [15:0] frame_left, frame_right
);
    reg signed [15:0] pending_left, pending_right;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_left <= 0;
            pending_right <= 0;
            frame_left <= 0;
            frame_right <= 0;
        end else begin
            // audio_core already saturates to signed 24-bit PCM.
            if (pcm_valid) begin
                pending_left <= pcm_left[23:8];
                pending_right <= pcm_right[23:8];
            end
            if (frame_start) begin
                frame_left <= pcm_valid ? pcm_left[23:8] : pending_left;
                frame_right <= pcm_valid ? pcm_right[23:8] : pending_right;
            end
        end
    end
endmodule

// Philips I2S, PCM5102A: 64 BCK per stereo frame, 24-bit signed PCM.
// WS changes one BCK before the next channel's MSB (low = left).
// Scheduler: clk_audio / 4 = BCK, clk_audio / 256 = frame rate.
// Latch BOTH channels together; a frame cannot mix two sample generations.
module i2s_tx_pcm5102a (
    input wire clk_audio, rst_n, bck_in, bck_en,
    input wire signed [23:0] sample_l, sample_r,
    output wire frame_start, o_bck,
    output reg o_ws, o_din
);
    reg [5:0] bit_index;
    reg [63:0] shift_word;
    reg ws_pending, din_pending;
    wire falling_bck = bck_en && bck_in;
    wire [5:0] next_bit = bit_index + 1'b1;
    assign o_bck = bck_in;
    assign frame_start = falling_bck && bit_index == 6'd63;

    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) begin
            bit_index <= 63;
            shift_word <= 0;
            ws_pending <= 1;
            din_pending <= 0;
        end else if (falling_bck) begin
            bit_index <= next_bit;
            ws_pending <= next_bit[5];
            // Boundary bit belongs to the previous channel, as I2S requires.
            din_pending <= shift_word[63];
            if (next_bit == 0)
                shift_word <= {sample_l, 8'd0, sample_r, 8'd0};
            else
                shift_word <= {shift_word[62:0], 1'b0};
        end
    end
    // BCK falls at posedge clk_audio. Launch WS/DIN half a clk_audio later,
    // leaving 1.5 clk_audio cycles of setup before the next BCK rising edge.
    always @(negedge clk_audio or negedge rst_n) begin
        if (!rst_n) begin o_ws <= 1; o_din <= 0; end
        else begin o_ws <= ws_pending; o_din <= din_pending; end
    end
endmodule

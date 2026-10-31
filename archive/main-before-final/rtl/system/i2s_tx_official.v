//=============================================================================
// i2s_tx_official.v
//
// Tang Mega 138K 板载 DAC 的官方 audio_drive.v 兼容实现。
// 官方驱动的实际时序：
//   * BCK = 1.536 MHz，每帧 32 个 BCK（左右各 16 bit）
//   * 数据和 WS 在 BCK 上升沿寄存器更新
//   * 请求在 b_cnt=0/16 产生，数据在下一拍装载（req 延迟一拍）
//   * WS 在 b_cnt=3 置左、b_cnt=19 置右
//
// bck_in 由 sample_scheduler 产生。bck_en 脉冲到来且 bck_in 为 0 时，
// scheduler 将在当前 clk_audio 边沿后把 BCK 拉高，这正是官方驱动的
// posedge clk_1p536m 行为。
//=============================================================================
module i2s_tx_official (
    input  wire        clk_audio,
    input  wire        rst_n,
    input  wire        bck_in,
    input  wire        bck_en,
    input  wire signed [15:0] sample_l,
    input  wire signed [15:0] sample_r,
    output wire        frame_start,
    output wire        o_bck,
    output reg         o_ws,
    output reg         o_din
);

    reg [4:0]  b_cnt;
    reg        req_r;
    reg        req_r1;
    reg [15:0] idata_r;

    wire bck_rise_event = bck_en && !bck_in;
    wire [15:0] selected_data = (b_cnt < 5'd16) ? sample_l : sample_r;

    assign o_bck       = bck_in;
    assign frame_start = bck_rise_event && (b_cnt == 5'd0);

    always @(posedge clk_audio or negedge rst_n) begin
        if (!rst_n) begin
            b_cnt   <= 5'd0;
            req_r   <= 1'b0;
            req_r1  <= 1'b0;
            idata_r <= 16'd0;
            o_ws    <= 1'b0;
            o_din   <= 1'b0;
        end else if (bck_rise_event) begin
            b_cnt  <= b_cnt + 1'b1;
            req_r  <= (b_cnt == 5'd0) || (b_cnt == 5'd16);
            req_r1 <= req_r;

            if (req_r1)
                idata_r <= selected_data;
            else
                idata_r <= idata_r << 1;

            o_din <= idata_r[15];
            o_ws  <= (b_cnt == 5'd3) ? 1'b0 :
                     (b_cnt == 5'd19) ? 1'b1 : o_ws;
        end
    end

endmodule

//=============================================================================
// reset_sync.v —— 复位同步器（异步置位、同步释放）
// 归属：成员 C 维护（rtl/common/），A/B/C 共同使用。
//=============================================================================
module reset_sync #(
    parameter SYNC_STAGES = 3
) (
    input  wire clk,
    input  wire arst_n,      // 异步复位输入，低有效
    output wire rst_n        // 同步释放后的复位，低有效
);
    reg [SYNC_STAGES-1:0] sync_ff;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) sync_ff <= {SYNC_STAGES{1'b0}};
        else         sync_ff <= {sync_ff[SYNC_STAGES-2:0], 1'b1};
    end

    assign rst_n = sync_ff[SYNC_STAGES-1];
endmodule

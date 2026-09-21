`timescale 1ns/1ps
//=============================================================================
// reset_sync —— 复位同步器（异步置位、同步释放）
// 归属：成员 C 维护，A/B/C 共同使用。修改前必须提交接口变更说明。
//=============================================================================
module reset_sync (
    input  wire clk,
    input  wire arst_n,      // 异步复位输入，低有效
    output wire rst_n        // 同步释放后的复位，低有效
);
    reg [2:0] sync_ff;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) sync_ff <= 3'b000;
        else         sync_ff <= {sync_ff[1:0], 1'b1};
    end

    assign rst_n = sync_ff[2];
endmodule

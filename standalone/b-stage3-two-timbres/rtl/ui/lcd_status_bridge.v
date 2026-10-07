// Atomic audio-domain snapshot transferred by a request/acknowledge toggle.
// The source holds its payload until the next destination request.
module lcd_status_bridge #(parameter integer WIDTH = 56) (
    input wire source_clk, source_rst_n,
    input wire [WIDTH-1:0] source_status,
    input wire pixel_clk, pixel_rst_n, frame_start,
    output reg [WIDTH-1:0] pixel_status
);
    reg request, acknowledge;
    reg request_meta, request_sync, ack_meta, ack_sync;
    reg [WIDTH-1:0] held_status;
    reg busy;
    always @(posedge source_clk or negedge source_rst_n) begin
        if (!source_rst_n) begin
            request_meta <= 0; request_sync <= 0;
            acknowledge <= 0; held_status <= 0;
        end else begin
            request_meta <= request;
            request_sync <= request_meta;
            if (request_sync != acknowledge) begin
                held_status <= source_status;
                acknowledge <= request_sync;
            end
        end
    end
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            request <= 0; ack_meta <= 0; ack_sync <= 0;
            busy <= 0; pixel_status <= 0;
        end else begin
            ack_meta <= acknowledge;
            ack_sync <= ack_meta;
            if (busy && ack_sync == request) begin
                pixel_status <= held_status;
                busy <= 0;
            end else if (frame_start && !busy) begin
                request <= ~request;
                busy <= 1;
            end
        end
    end
endmodule

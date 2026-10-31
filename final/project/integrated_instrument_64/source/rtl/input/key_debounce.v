`timescale 1ns/1ps
// key_raw: 1 = pressed. Release rst_n synchronously to clk.
// Stable time = DEBOUNCE_CYCLES / clock frequency; minimum cycles is 1.
// Default example: 1 ms at 50 MHz. Actual board timing must be configured.
// For a matrix keyboard, input a held per-key state, not a raw column wire.
module key_debounce #(
    parameter integer DEBOUNCE_CYCLES = 50000
) (
    input wire clk,
    input wire rst_n,
    input wire key_raw,
    output reg key_stable,
    output reg key_press,
    output reg key_release
);
    function integer count_width;
        input integer n;
        integer v;
        begin
            v = n - 1;
            count_width = 0;
            while (v > 0) begin
                count_width = count_width + 1;
                v = v >> 1;
            end
            if (count_width < 1) count_width = 1;
        end
    endfunction
    localparam integer WIDTH = count_width(DEBOUNCE_CYCLES);
    localparam [WIDTH-1:0] LAST = DEBOUNCE_CYCLES - 1;
    reg [WIDTH-1:0] count;
    reg key_meta, key_sync;

    // Two-stage asynchronous input synchronization.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_meta <= 0;
            key_sync <= 0;
        end else begin
            key_meta <= key_raw;
            key_sync <= key_meta;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= 0;
            key_stable <= 0;
            key_press <= 0;
            key_release <= 0;
        end else begin
            key_press <= 0;
            key_release <= 0;
            if (key_sync == key_stable) begin
                count <= 0;
            end else if (count == LAST) begin
                count <= 0;
                key_stable <= key_sync;
                key_press <= key_sync;
                key_release <= ~key_sync;
            end else begin
                count <= count + 1'b1;
            end
        end
    end
endmodule

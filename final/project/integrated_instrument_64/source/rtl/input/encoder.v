`timescale 1ns/1ps
// EC11C01V01-0027: 20 pulses and 20 detents per revolution.
// {A,B} CW sequence (datasheet fig.3): 11 -> 10 -> 00 -> 01 -> 11.
// C connects to GND; A/B need pullups to the FPGA bank's legal IO voltage.
// D/E push switch is separate and is NOT decoded by this module.
// FILTER_CYCLES >= 1. Default is 50 us ONLY with a 50 MHz clock.
// This short filter rejects glitches, NOT all millisecond contact bounce.
// Legal backtracking cancels partial motion; four net edges emit one step.
// Each real phase must remain stable longer than the filter plus sync delay.
// Illegal two-bit changes discard partial motion (lost motion is not guessed).
// Startup anchors at the first stable phase; a partial first detent may be lost.
// Outputs are one-clock pulses. Release rst_n synchronously to clk.
module encoder #(
    parameter integer FILTER_CYCLES = 2500,
    parameter integer REVERSE_DIR = 0
) (
    input wire clk,
    input wire rst_n,
    input wire enc_a,
    input wire enc_b,
    output reg step_up,
    output reg step_down,
    output reg input_ready
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
    localparam integer WIDTH = count_width(FILTER_CYCLES);
    localparam [WIDTH-1:0] LAST = FILTER_CYCLES - 1;
    reg [1:0] ab_meta, ab_sync, candidate, previous;
    reg [2:0] sync_valid;
    reg [WIDTH-1:0] stable_count;
    reg signed [3:0] motion;
    reg signed [3:0] delta;

    always @* begin
        delta = 0;
        case ({previous, ab_sync})
            4'b1110, 4'b1000, 4'b0001, 4'b0111: delta = 1;
            4'b1101, 4'b0100, 4'b0010, 4'b1011: delta = -1;
            default: delta = 0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ab_meta <= 0;
            ab_sync <= 0;
            sync_valid <= 0;
        end else begin
            ab_meta <= {enc_a, enc_b};
            ab_sync <= ab_meta;
            sync_valid <= {sync_valid[1:0], 1'b1};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            candidate <= 0;
            previous <= 0;
            stable_count <= 0;
            motion <= 0;
            input_ready <= 0;
            step_up <= 0;
            step_down <= 0;
        end else begin
            step_up <= 0;
            step_down <= 0;
            if (sync_valid[2]) begin
                if (ab_sync != candidate) begin
                    candidate <= ab_sync;
                    stable_count <= 1;
                end else if (stable_count != LAST) begin
                    stable_count <= stable_count + 1'b1;
                end
                // New candidate's first sample counts toward FILTER_CYCLES.
                if ((FILTER_CYCLES == 1) ||
                    ((ab_sync == candidate) && (stable_count == LAST))) begin
                    if (!input_ready) begin
                        previous <= ab_sync;
                        motion <= 0;
                        input_ready <= 1;
                    end else if (ab_sync != previous) begin
                        previous <= ab_sync;
                        if (delta == 0) begin
                            motion <= 0;
                        end else if ((motion == 3) && (delta == 1)) begin
                            motion <= 0;
                            step_up <= (REVERSE_DIR == 0);
                            step_down <= (REVERSE_DIR != 0);
                        end else if ((motion == -3) && (delta == -1)) begin
                            motion <= 0;
                            step_down <= (REVERSE_DIR == 0);
                            step_up <= (REVERSE_DIR != 0);
                        end else begin
                            motion <= motion + delta;
                        end
                    end
                end
            end
        end
    end
endmodule

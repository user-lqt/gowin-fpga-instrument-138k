`timescale 1ns/1ps
// Matrix-specific debounce: count distinct full scans, not held clock samples.
// ROW_CYCLES >= 4; DEBOUNCE_FRAMES >= 1.
// Example at 50 MHz: 0.4 ms/frame, 5 matching observations to confirm.
// Actual input latency also includes scan phase and publication delay.
// No ghost suppression: a diode-less keyboard cannot resolve all chords.
module matrix_keyboard #(
    parameter integer ROW_CYCLES = 5000,
    parameter integer DEBOUNCE_FRAMES = 5
) (
    input wire clk,
    input wire rst_n,
    input wire [3:0] col_in,
    output wire [3:0] row_out,
    output reg [15:0] key_state,
    output reg [15:0] key_press,
    output reg [15:0] key_release,
    output reg input_ready
);
    function integer width_for;
        input integer n;
        integer v;
        begin
            v = n - 1;
            width_for = 0;
            while (v > 0) begin
                width_for = width_for + 1;
                v = v >> 1;
            end
            if (width_for < 1) width_for = 1;
        end
    endfunction
    localparam integer WIDTH = width_for(DEBOUNCE_FRAMES);
    localparam [WIDTH-1:0] LAST = DEBOUNCE_FRAMES - 1;
    wire [15:0] raw;
    wire scan_valid;
    reg [WIDTH-1:0] count [0:15];
    reg [WIDTH-1:0] ready_count;
    integer k;
    matrix_scan #(.ROW_CYCLES(ROW_CYCLES)) scanner (
        .clk(clk), .rst_n(rst_n), .col_in(col_in), .row_out(row_out),
        .key_raw(raw), .scan_valid(scan_valid)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_state <= 0;
            key_press <= 0;
            key_release <= 0;
            input_ready <= 0;
            ready_count <= 0;
            for (k = 0; k < 16; k = k + 1) count[k] <= 0;
        end else begin
            key_press <= 0;
            key_release <= 0;
            if (scan_valid) begin
                if (!input_ready) begin
                    if (ready_count == LAST) input_ready <= 1;
                    else ready_count <= ready_count + 1'b1;
                end
                for (k = 0; k < 16; k = k + 1) begin
                    if (raw[k] == key_state[k]) count[k] <= 0;
                    else if (count[k] == LAST) begin
                        count[k] <= 0;
                        key_state[k] <= raw[k];
                        key_press[k] <= raw[k];
                        key_release[k] <= ~raw[k];
                    end else count[k] <= count[k] + 1'b1;
                end
            end
        end
    end
endmodule

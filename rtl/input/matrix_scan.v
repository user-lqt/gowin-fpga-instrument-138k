`timescale 1ns/1ps
// Raw 4x4 matrix scan. No debounce or NOTE events in this module.
// ROW_CYCLES >= 4 allows external settling and two-stage synchronization.
// Default example at 50 MHz: 100 us/row, 400 us/frame.
// Columns require pull-ups to the appropriate FPGA I/O supply (3.3 V here).
// Place row tri-state buffers at physical I/O when integrating into the top.
module matrix_scan #(
    parameter integer ROW_CYCLES = 5000
) (
    input wire clk,
    input wire rst_n,
    input wire [3:0] col_in,
    output wire [3:0] row_out,
    output reg [15:0] key_raw,
    output reg scan_valid
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
    localparam integer WIDTH = width_for(ROW_CYCLES);
    localparam [WIDTH-1:0] LAST = ROW_CYCLES - 1;
    reg [WIDTH-1:0] count;
    reg [1:0] row_index;
    reg [3:0] col_meta, col_sync;
    reg [15:0] frame;
    genvar r;
    generate
        for (r = 0; r < 4; r = r + 1) begin: rows
            assign row_out[r] = (rst_n && row_index == r) ? 1'b0 : 1'bz;
        end
    endgenerate
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_meta <= 4'hf;
            col_sync <= 4'hf;
        end else begin
            col_meta <= col_in;
            col_sync <= col_meta;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= 0;
            row_index <= 0;
            frame <= 0;
            key_raw <= 0;
            scan_valid <= 0;
        end else begin
            scan_valid <= 0;
            if (count == LAST) begin
                count <= 0;
                case (row_index)
                    0: frame[3:0] <= ~col_sync;
                    1: frame[7:4] <= ~col_sync;
                    2: frame[11:8] <= ~col_sync;
                    3: begin
                        // Publish a complete frame, including the current row.
                        key_raw <= {~col_sync, frame[11:0]};
                        scan_valid <= 1;
                    end
                endcase
                row_index <= row_index + 1'b1;
            end else count <= count + 1'b1;
        end
    end
endmodule

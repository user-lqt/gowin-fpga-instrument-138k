`timescale 1ns/1ps
// 8-row x 6-column diode-isolated scanner for the 24-key dual-contact keyboard.
// Each scan row is driven low in turn; all other rows are high impedance.
// col_in is pulled up to 3.3 V. A closed contact therefore reads 0.
module matrix_scan_8x6 #(
    parameter integer ROW_CYCLES = 5000
) (
    input wire clk,
    input wire rst_n,
    input wire [5:0] col_in,
    output wire [7:0] row_out,
    output reg [47:0] contact_raw,
    output reg scan_valid
);
    function integer width_for;
        input integer n;
        integer v;
        begin
            v = n - 1; width_for = 0;
            while (v > 0) begin width_for = width_for + 1; v = v >> 1; end
            if (width_for < 1) width_for = 1;
        end
    endfunction
    localparam integer CW = width_for(ROW_CYCLES);
    localparam [CW-1:0] LAST = ROW_CYCLES - 1;
    reg [CW-1:0] count;
    reg [2:0] row_index;
    reg [5:0] col_meta, col_sync;
    reg [47:0] frame;
    genvar r;
    generate for (r = 0; r < 8; r = r + 1) begin: g_rows
        assign row_out[r] = (rst_n && row_index == r[2:0]) ? 1'b0 : 1'bz;
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin col_meta <= 6'h3f; col_sync <= 6'h3f; end
        else begin col_meta <= col_in; col_sync <= col_meta; end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin count <= 0; row_index <= 0; frame <= 0; contact_raw <= 0; scan_valid <= 0; end
        else begin
            scan_valid <= 1'b0;
            if (count == LAST) begin
                count <= 0;
                case (row_index)
                    3'd0: frame[5:0]   <= ~col_sync;
                    3'd1: frame[11:6]  <= ~col_sync;
                    3'd2: frame[17:12] <= ~col_sync;
                    3'd3: frame[23:18] <= ~col_sync;
                    3'd4: frame[29:24] <= ~col_sync;
                    3'd5: frame[35:30] <= ~col_sync;
                    3'd6: frame[41:36] <= ~col_sync;
                    3'd7: begin
                        contact_raw <= {~col_sync, frame[41:0]};
                        scan_valid <= 1'b1;
                    end
                endcase
                row_index <= row_index + 1'b1;
            end else count <= count + 1'b1;
        end
    end
endmodule

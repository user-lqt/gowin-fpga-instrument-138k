`timescale 1ns/1ps
module tb_matrix_scan;
    parameter integer TEST_ROW_CYCLES = 8;
    reg clk = 0;
    reg rst_n = 0;
    reg [15:0] pressed = 0;
    wire [3:0] rows;
    reg [3:0] cols;
    wire [15:0] key_raw;
    wire scan_valid;
    integer errors = 0;
    integer i, j, pass;
    reg [3:0] low_rows, low_cols;
    integer k;
    reg [15:0] last_keys = 0;
    reg last_valid = 0;
    integer clocks = 0;
    integer last_frame = 0;
    matrix_scan #(.ROW_CYCLES(TEST_ROW_CYCLES)) dut (
        .clk(clk), .rst_n(rst_n), .col_in(cols), .row_out(rows),
        .key_raw(key_raw), .scan_valid(scan_valid)
    );
    always #10 clk = ~clk;

    // Electrical model: closed switches propagate low in BOTH directions.
    // This models ghost paths through floating rows, not just ideal key lookup.
    always @* begin
        low_rows = 0;
        low_cols = 0;
        for (i = 0; i < 4; i = i + 1)
            if (rows[i] === 1'b0) low_rows[i] = 1;
        for (pass = 0; pass < 8; pass = pass + 1)
            for (i = 0; i < 4; i = i + 1)
                for (j = 0; j < 4; j = j + 1)
                    if (pressed[4*i+j]) begin
                        if (low_rows[i]) low_cols[j] = 1;
                        if (low_cols[j]) low_rows[i] = 1;
                    end
        cols = ~low_cols;
    end

    always @(posedge clk) begin
        #1;
        if (!rst_n) begin
            last_keys = 0;
            last_valid = 0;
            clocks = 0;
            last_frame = 0;
            if (rows !== 4'bzzzz || key_raw !== 0 || scan_valid !== 0)
                errors = errors + 1;
        end else begin
            clocks = clocks + 1;
            if (rows !== 4'bzzz0 && rows !== 4'bzz0z &&
                rows !== 4'bz0zz && rows !== 4'b0zzz) begin
                $display("FAIL: row drive %b", rows); errors = errors + 1;
            end
            if ((!scan_valid && key_raw !== last_keys) ||
                (scan_valid && last_valid)) errors = errors + 1;
            if (scan_valid) begin
                if (clocks - last_frame != 4 * TEST_ROW_CYCLES)
                    errors = errors + 1;
                last_frame = clocks;
            end
            last_valid = scan_valid;
            last_keys = key_raw;
        end
    end

    task check_pattern;
        input [15:0] keys;
        input [15:0] expected;
        begin
            @(negedge clk); pressed = keys;
            // First frame may contain rows sampled before the change.
            repeat (2) begin
                @(posedge scan_valid); #2;
            end
            if (key_raw !== expected) begin
                $display("FAIL: pressed=%h read=%h expected=%h", keys, key_raw, expected);
                errors = errors + 1;
            end
        end
    endtask
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        check_pattern(0, 0);
        for (k = 0; k < 16; k = k + 1) begin
            check_pattern(16'h0001 << k, 16'h0001 << k);
            check_pattern(0, 0);
        end
        check_pattern(16'h000f, 16'h000f); // Same row.
        check_pattern(16'h1111, 16'h1111); // Same column.
        check_pattern(16'h8421, 16'h8421); // Independent diagonal keys.
        check_pattern(16'h0013, 16'h0033); // S1,S2,S5 produce ghost S6.
        check_pattern(0, 0);
        check_pattern(16'hffff, 16'hffff);
        @(negedge clk); rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        check_pattern(16'h8000, 16'h8000);
        check_pattern(0, 0);
        if (errors == 0) $display("PASS: matrix scan, all 16 keys, frame timing, reset and ghost model; row cycles=%0d", TEST_ROW_CYCLES);
        else $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1, "FAIL: timeout");
    end
endmodule

// Select this simulation top to check the minimum supported row period.
module tb_matrix_scan_min;
    tb_matrix_scan #(.TEST_ROW_CYCLES(4)) test_case();
endmodule

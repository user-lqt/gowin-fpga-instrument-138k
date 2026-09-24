`timescale 1ns/1ps
// First B1 test: single-key debounce only, without matrix scanning.
module tb_input;
    parameter integer TEST_CYCLES = 4;
    reg clk = 0;
    reg rst_n = 0;
    reg key_raw = 0;
    wire key_stable, key_press, key_release;
    integer presses = 0;
    integer releases = 0;
    integer errors = 0;
    reg prev_press = 0;
    reg prev_release = 0;
    key_debounce #(.DEBOUNCE_CYCLES(TEST_CYCLES)) dut (
        .clk(clk), .rst_n(rst_n), .key_raw(key_raw),
        .key_stable(key_stable), .key_press(key_press),
        .key_release(key_release)
    );
    always #10 clk = ~clk; // Simulation clock only: 50 MHz.
    always @(posedge clk) begin
        #1;
        if (!rst_n) begin
            prev_press = 0;
            prev_release = 0;
        end else begin
            if ((key_press && key_release) ||
                (key_press && prev_press) || (key_release && prev_release) ||
                (key_press && !key_stable) || (key_release && key_stable)) begin
                errors = errors + 1;
                $display("FAIL: invalid pulse at %0t", $time);
            end
            if (key_press) presses = presses + 1;
            if (key_release) releases = releases + 1;
            prev_press = key_press;
            prev_release = key_release;
        end
    end
    task drive;
        input value;
        input integer cycles;
        begin
            @(negedge clk); key_raw = value;
            repeat (cycles) @(posedge clk);
            #2;
        end
    endtask
    task check;
        input state;
        input integer p;
        input integer r;
        begin
            if (key_stable !== state || presses != p || releases != r) begin
                errors = errors + 1;
                $display("FAIL at %0t: state/press/release=%b/%0d/%0d expected=%b/%0d/%0d",
                    $time, key_stable, presses, releases, state, p, r);
            end
        end
    endtask
    initial begin
        // Wave recording is owned by run_wave.tcl for all regression tests.
        repeat (3) @(negedge clk);
        rst_n = 1;
        drive(0, TEST_CYCLES + 5); check(0, 0, 0);
        // Sub-threshold pulses must not change the state.
        if (TEST_CYCLES > 1) begin
            drive(1, TEST_CYCLES - 1);
            drive(0, TEST_CYCLES + 5); check(0, 0, 0);
            drive(1, 1);
            drive(0, TEST_CYCLES + 5); check(0, 0, 0);
        end
        // N confirmation cycles plus two synchronizer cycles.
        drive(1, TEST_CYCLES + 1); check(0, 0, 0);
        @(posedge clk); #2; check(1, 1, 0);
        drive(1, 4 * TEST_CYCLES + 5); check(1, 1, 0);
        if (TEST_CYCLES > 1) begin
            drive(0, TEST_CYCLES - 1);
            drive(1, TEST_CYCLES + 5); check(1, 1, 0);
        end
        drive(0, TEST_CYCLES + 2); check(0, 1, 1);
        drive(0, TEST_CYCLES + 5); check(0, 1, 1);
        drive(1, TEST_CYCLES + 2); check(1, 2, 1);
        // Reset clears state; a key held through reset is detected anew.
        @(negedge clk); rst_n = 0;
        #2; check(0, 2, 1);
        if (key_press !== 0 || key_release !== 0) errors = errors + 1;
        repeat (3) @(negedge clk);
        rst_n = 1;
        repeat (TEST_CYCLES + 2) @(posedge clk);
        #2; check(1, 3, 1);
        drive(0, TEST_CYCLES + 2); check(0, 3, 2);
        if (errors == 0)
            $display("PASS: key_debounce cycles=%0d; all checks passed", TEST_CYCLES);
        else $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1, "FAIL: simulation timeout");
    end
endmodule

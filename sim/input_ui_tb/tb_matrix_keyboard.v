`timescale 1ns/1ps
module tb_matrix_keyboard;
    reg clk = 0, rst_n = 0;
    reg [15:0] pressed = 0;
    wire [3:0] rows;
    reg [3:0] cols;
    wire [15:0] state, press_pulse, release_pulse;
    wire ready;
    reg [3:0] low_rows, low_cols;
    integer i,j,p,k;
    integer errors = 0;
    integer on_count [0:15];
    integer off_count [0:15];
    reg [15:0] prev_state = 0;
    matrix_keyboard #(.ROW_CYCLES(8), .DEBOUNCE_FRAMES(3)) dut (
        .clk(clk), .rst_n(rst_n), .col_in(cols), .row_out(rows),
        .key_state(state), .key_press(press_pulse),
        .key_release(release_pulse), .input_ready(ready)
    );
    always #10 clk = ~clk;
    // Passive switch network, including ghost conduction paths.
    always @* begin
        low_rows = 0; low_cols = 0;
        for (i=0;i<4;i=i+1) if (rows[i] === 1'b0) low_rows[i]=1;
        for (p=0;p<8;p=p+1)
            for (i=0;i<4;i=i+1)
                for (j=0;j<4;j=j+1) if (pressed[4*i+j]) begin
                    if (low_rows[i]) low_cols[j]=1;
                    if (low_cols[j]) low_rows[i]=1;
                end
        cols = ~low_cols;
    end
    always @(posedge clk) begin
        #1;
        if (!rst_n) prev_state=0;
        else begin
            if (press_pulse !== (state & ~prev_state) ||
                release_pulse !== (~state & prev_state)) errors=errors+1;
            for (k=0;k<16;k=k+1) begin
                if (press_pulse[k]) on_count[k]=on_count[k]+1;
                if (release_pulse[k]) off_count[k]=off_count[k]+1;
            end
            prev_state=state;
        end
    end
    task frames;
        input integer n;
        begin
            repeat(n) begin
                @(posedge dut.scan_valid);
                @(posedge clk); #2;
            end
        end
    endtask
    task check;
        input [15:0] expected;
        begin
            if (state !== expected) begin
                $display("FAIL state=%h expected=%h",state,expected);
                errors=errors+1;
            end
        end
    endtask
    initial begin
        for (p=0;p<16;p=p+1) begin on_count[p]=0;off_count[p]=0;end
        repeat(3) @(negedge clk);
        rst_n=1;
        frames(2);
        if (ready !== 0) errors=errors+1;
        frames(1);
        if (ready !== 1) errors=errors+1;
        check(0);
        // Each full scan alternates: no confirmed press.
        repeat(3) begin
            @(negedge clk); pressed=16'hffff;
            frames(1); check(0);
            @(negedge clk); pressed=0;
            frames(1); check(0);
        end
        @(negedge clk); pressed=16'hffff;
        frames(2); check(0);
        frames(1); check(16'hffff);
        frames(5); check(16'hffff);
        // Release bounce while all keys remain logically held.
        @(negedge clk); pressed=0;
        frames(1); check(16'hffff);
        @(negedge clk); pressed=16'hffff;
        frames(1); check(16'hffff);
        // Independent release counters: keep one column pressed.
        @(negedge clk); pressed=16'h1111;
        frames(2); check(16'hffff);
        frames(1); check(16'h1111);
        @(negedge clk); pressed=0;
        frames(3); check(0);
        for (p=0;p<16;p=p+1)
            if (on_count[p]!=1 || off_count[p]!=1) errors=errors+1;
        // Held key across reset: state clears and is acquired again.
        @(negedge clk); pressed=16'h8000;
        frames(3); check(16'h8000);
        @(negedge clk); rst_n=0;
        #2; check(0);
        if (ready !== 0 || press_pulse !== 0 || release_pulse !== 0) errors=errors+1;
        repeat(3) @(negedge clk);
        rst_n=1;
        frames(3); check(16'h8000);
        if(errors==0) $display("PASS: matrix keyboard debounce, multi-key pulses, hold, release and reset");
        else $fatal(1,"FAIL: %0d errors",errors);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1,"FAIL: timeout");
    end
endmodule

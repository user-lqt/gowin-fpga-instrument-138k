`timescale 1ns/1ps
module tb_pitch_vibrato;
    reg clk=0,rst_n=0,tick=0,valid=0;
    reg [3:0] id=3;
    reg [15:0] value=0;
    wire signed [23:0] offset;
    integer n, peak_high, peak_low, previous, last_cross, periods;
    reg [23:0] saved_phase;
    pitch_vibrato dut(.clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .param_valid(valid),.param_id(id),.param_value(value),.pitch_offset(offset));
    always #5 clk=~clk;
    task depth;
        input [15:0] target;
        begin
            @(negedge clk);value=target;valid=1;
            @(negedge clk);valid=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;tick=1;
        depth(65535);repeat(260) @(negedge clk);
        if(dut.depth!=65535) $fatal(1,"vibrato depth did not settle");
        peak_high=0;peak_low=0;previous=offset;last_cross=-1;periods=0;
        for(n=0;n<30000;n=n+1) begin
            @(negedge clk);
            if(offset>peak_high) peak_high=offset;
            if(offset<peak_low) peak_low=offset;
            if(previous<0 && offset>=0) begin
                if(last_cross>=0) begin
                    if(n-last_cross<9590 || n-last_cross>9610)
                        $fatal(1,"vibrato frequency not 5 Hz at 48 kHz");
                    periods=periods+1;
                end
                last_cross=n;
            end
            previous=offset;
        end
        if(peak_high<32700 || peak_high>32768 || peak_low>-32700 ||
           peak_low< -32768 || periods<2) $fatal(1,"vibrato full-depth range");
        depth(32768);repeat(140) @(negedge clk);
        peak_high=0;peak_low=0;
        for(n=0;n<9700;n=n+1) begin
            @(negedge clk);
            if(offset>peak_high) peak_high=offset;
            if(offset<peak_low) peak_low=offset;
        end
        if(peak_high<16300 || peak_high>16384 || peak_low>-16300 || peak_low< -16384)
            $fatal(1,"vibrato half-depth range");
        depth(0);repeat(260) @(negedge clk);
        if(offset!=0 || dut.depth!=0) $fatal(1,"vibrato disable");
        saved_phase=dut.phase;repeat(10) @(negedge clk);
        if(dut.phase==saved_phase) $fatal(1,"zero depth stopped LFO phase");
        tick=0;saved_phase=dut.phase;repeat(10) @(negedge clk);
        if(dut.phase!=saved_phase) $fatal(1,"LFO advanced without sample_tick");
        $display("PASS vibrato 5 Hz, +/-50 cents, half depth, smooth disable and sample enable");
        $finish;
    end
    initial begin #500000;$fatal(1,"vibrato test timeout");end
endmodule

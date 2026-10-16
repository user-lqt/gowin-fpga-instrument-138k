`timescale 1ns/1ps
module tb_bell_audition;
    localparam integer LANES=6;
    reg clk=0,rst_n=0,tick=0;
    always #1 clk=~clk;
    reg [LANES-1:0] on=0,off=0;
    reg [LANES*32-1:0] fcs=0;
    wire [LANES*16-1:0] waves,levels;
    wire [LANES-1:0] active;
    bianzhong_ram_bank #(.LANES(LANES)) modes(.clk(clk),.rst_n(rst_n),
        .sample_tick(tick),.note_on(on),.fcs(fcs),
        .velocities({LANES{8'd110}}),.waves(waves));
    adsr_state_bank #(.VOICES(LANES)) envelope(.clk(clk),.rst_n(rst_n),
        .sample_tick(tick),.note_on(on),.note_off(off),
        .instruments({LANES{2'd2}}),.velocities({LANES{8'd110}}),
        .levels(levels),.stages(),.active(active));
    function [31:0] frequency;
        input integer note;
        real value;
        begin
            value=440.0*(2.0**((note-69)/12.0))*4294967296.0/48000.0;
            frequency=$rtoi(value);
        end
    endfunction
    integer n,j,out;
    reg signed [32:0] product;
    initial begin
        out=$fopen("bell_stems.csv","w");
        // Each column is an independent complete RTL strike, C5 through A5.
        fcs[31:0]=frequency(72);fcs[63:32]=frequency(74);
        fcs[95:64]=frequency(76);fcs[127:96]=frequency(77);
        fcs[159:128]=frequency(79);fcs[191:160]=frequency(81);
        repeat(3) @(negedge clk);rst_n=1;
        // 48 mode slots plus pipeline complete before the next sample.
        for(n=0;n<201600;n=n+1) begin
            @(negedge clk);tick=1;
            @(negedge clk);tick=0;
            on=n==0 ? {LANES{1'b1}} : 0;
            off=n==2400 ? {LANES{1'b1}} : 0;
            @(negedge clk);on=0;off=0;
            repeat(53) @(negedge clk);
            if(n==76800 && active!={LANES{1'b1}})
                $fatal(1,"tail reclaimed at old four-lane overwrite time");
            if(n>196800 && active!=0) $fatal(1,"stem did not finish naturally");
            for(j=0;j<LANES;j=j+1) begin
                product=$signed(waves[j*16+:16])*$signed({1'b0,levels[j*16+:16]});
                $fwrite(out,"%0d",product>>>16);
                if(j==LANES-1) $fwrite(out,"\n");
                else $fwrite(out,",");
            end
            if(n%48000==0) begin
                $display("Captured %0d seconds of six complete bell stems",n/48000);
                $fflush(out);
            end
        end
        $fclose(out);
        $display("PASS six actual RTL strikes, 50ms taps, complete independent tails, 4.2 seconds");
        $finish;
    end
endmodule

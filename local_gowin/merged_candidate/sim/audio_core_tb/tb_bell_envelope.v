`timescale 1ns/1ps
module tb_bell_envelope;
    reg clk=0,rst_n=0,tick=0;
    always #5 clk=~clk;
    reg [3:0] on=0,off=0;
    wire [63:0] levels,reference_levels;
    wire [11:0] stages,reference_stages;
    wire [3:0] active,reference_active;
    localparam [7:0] INSTRUMENTS={2'd2,2'd2,2'd1,2'd0};
    adsr_state_bank #(.VOICES(4)) bank(.clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .note_on(on),.note_off(off),.instruments(INSTRUMENTS),.velocities({4{8'd127}}),
        .levels(levels),.stages(stages),.active(active));
    genvar v;
    generate for(v=0;v<4;v=v+1) begin : reference
        adsr #(.ENABLE_TIMBRES(1)) envelope(.clk(clk),.rst_n(rst_n),
            .sample_tick(tick),.note_on(on[v]),.note_off(off[v]),
            .instrument(INSTRUMENTS[v*2+:2]),.velocity(8'd127),
            .shared_release_quotient(16'd0),.shared_release_modulus(16'd0),
            .level(reference_levels[v*16+:16]),.stage(reference_stages[v*3+:3]),
            .active(reference_active[v]));
    end endgenerate
    integer n,last_level=65535,logfile;
    task step;
        input [3:0] triggers,releases;
        begin
            @(negedge clk);tick=1;
            @(negedge clk);tick=0;on=triggers;off=releases;
            @(negedge clk);on=0;off=0;
            repeat(8) @(negedge clk);
            if(levels!==reference_levels || stages!==reference_stages ||
               active!==reference_active) $fatal(1,"shared/reference mismatch sample %d",n);
        end
    endtask
    initial begin
        logfile=$fopen("bell_envelope.csv","w");
        $fwrite(logfile,"sample,level\n");
        repeat(3) @(negedge clk);rst_n=1;
        for(n=0;n<192100;n=n+1) begin
            step(n==0 ? 4'b1111 : 4'd0,
                 n==100 ? 4'b0100 : n==3000 ? 4'b0011 : 4'd0);
            if(levels[47:32]!==levels[63:48])
                $fatal(1,"tap and held key have different bell tails");
            if(n>25 && levels[47:32]>last_level)
                $fatal(1,"bell amplitude rose during decay");
            if(n>25) last_level=levels[47:32];
            if(n==4800 && (last_level<60000 || last_level>62000)) $fatal(1,"early decay");
            if(n==24000 && (last_level<44000 || last_level>47000)) $fatal(1,"half-second decay");
            if(n==48000 && (last_level<30000 || last_level>33000)) $fatal(1,"one-second decay");
            if(n==96000 && (last_level<14000 || last_level>16000)) $fatal(1,"two-second resonance");
            if(n%4800==0) $fwrite(logfile,"%0d,%0d\n",n,levels[47:32]);
        end
        if(active!=0 || levels!=0) $fatal(1,"finite release/held bell reclaim");
        step(4'b1100,0);
        repeat(50) step(0,0);
        step(4'b1100,0);
        if(levels[63:32]!=0) $fatal(1,"retrigger did not reset envelope");
        repeat(30) step(0,0);
        if(levels[47:32]<64000) $fatal(1,"retrigger attack failed");
        $fclose(logfile);
        $display("PASS default-duration bell decay, tap/hold equality, retrigger, shared/reference all timbres");
        $finish;
    end
endmodule

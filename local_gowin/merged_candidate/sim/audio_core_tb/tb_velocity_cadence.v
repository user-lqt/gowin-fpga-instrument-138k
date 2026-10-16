`timescale 1ns/1ps
module tb_velocity_cadence;
    reg clk=0,rst_n=0,tick=0,ev=0,pv=0;
    always #5 clk=~clk;
    reg [1:0] kind=1;
    reg [6:0] note=48;
    reg [15:0] timbre=0;
    wire valid,ready,overflow,p_overflow,overload;
    wire signed [23:0] left,right;
    wire [5:0] count;
    integer div=0,cycle=0,last_tick=0,last_valid=0,t,n,frames=0;
    audio_core #(.RELEASE_SAMPLES(64)) dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .event_valid(ev),.event_type(kind),.note_id(note),.velocity(8'd127),
        .param_valid(pv),.param_id(4'd1),.param_value(timbre),
        .audio_core_valid(valid),.audio_left(left),.audio_right(right),
        .active_voice_count(count),.engine_ready(ready),.overload_flag(overload),
        .event_overflow(overflow),.param_overflow(p_overflow));
    always @(posedge clk) begin
        if(!rst_n) begin div<=0;tick<=0;end
        else begin div<=div==255 ? 0 : div+1;tick<=div==255;end
        cycle=cycle+1;
        if(tick) last_tick=cycle;
        #1;
        if(!rst_n) last_valid=0;
        else if(valid) begin
            if(cycle-last_tick!=109 || (last_valid!=0 && cycle-last_valid!=256))
                $fatal(1,"32-voice sample deadline failed");
            if((^left)===1'bx || left!==right || overflow || p_overflow)
                $fatal(1,"PCM/queue fault");
            last_valid=cycle;frames=frames+1;
        end
    end
    task samples;
        input integer amount;
        integer i;
        begin for(i=0;i<amount;i=i+1) begin @(posedge valid);@(negedge clk);end end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;wait(ready);
        for(t=0;t<3;t=t+2) begin
            @(negedge clk);timbre=t;pv=1;
            @(negedge clk);pv=0;samples(2);
            for(n=0;n<32;n=n+1) begin
                note=48+n;kind=1;ev=1;
                @(negedge clk);ev=0;samples(2);
            end
            samples(1024);
            if(count!=32) $fatal(1,"32 voices not retained");
            for(n=0;n<32;n=n+1) begin
                if(dut.a2.voice_note_id[n*7+:7]!=48+n)
                    $fatal(1,"voice allocation mismatch");
                note=48+n;kind=2;ev=1;
                @(negedge clk);ev=0;samples(2);
            end
            samples(128);
            if(count!=0 || left!=0) $fatal(1,"release failed");
            $display("PASS timbre %0d: 32 voices, latency109, period256, release",t);
        end
        $display("PASS 32-voice cadence %0d frames",frames);$finish;
    end
    initial begin #20000000;$fatal(1,"cadence timeout");end
endmodule

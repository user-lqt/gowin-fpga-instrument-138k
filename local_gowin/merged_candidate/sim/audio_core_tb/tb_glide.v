`timescale 1ns/1ps
`include "event_defs.vh"
module tb_glide;
    wire normal_done,optimized_done;
    // Exercise padded source selection and the complete instrument's 32-slot,
    // synchronous-lookup / bounded-period configuration independently.
    glide_scenario #(.VOICES(5),.OPTIMIZED(0)) normal(normal_done);
    glide_scenario #(.VOICES(32),.OPTIMIZED(1)) optimized(optimized_done);
    initial begin
        wait(normal_done && optimized_done);
        $display("PASS legato glide: first/detached notes, held-key priority, tails, chaining, both directions, retrigger and bypass");
        $finish;
    end
    initial begin #10000000;$fatal(1,"glide timeout");end
endmodule

module glide_scenario #(parameter VOICES=5,OPTIMIZED=0)(output reg done=0);
    reg clk=0,rst=0,tick=0,pv=0;
    always #5 clk=~clk;
    reg [VOICES-1:0] on=0,held=0;
    reg [VOICES*7-1:0] notes=0;
    wire [VOICES*32-1:0] bases,fcs;
    wire [VOICES*48-1:0] base_periods,periods;
    reg [15:0] glide=48;
    wire [31:0] fc48,fc60,fc67,fc72;
    wire [47:0] p48,p60,p67,p72;
    note_to_fc f0(7'd48,fc48),f1(7'd60,fc60),f2(7'd67,fc67),f3(7'd72,fc72);
    note_to_period p0(7'd48,p48),p1(7'd60,p60),p2(7'd67,p67),p3(7'd72,p72);
    genvar v;
    generate for(v=0;v<VOICES;v=v+1) begin : base_lookup
        note_to_fc f(notes[v*7+:7],bases[v*32+:32]);
        note_to_period p(notes[v*7+:7],base_periods[v*48+:48]);
    end endgenerate
    pitch_expression_bank #(.VOICES(VOICES),.STATIC_BASE_PITCH(OPTIMIZED),
        .BOUNDED_PERIOD(OPTIMIZED),.SYNC_LOOKUP(OPTIMIZED)) dut(
        .clk(clk),.rst_n(rst),.sample_tick(tick),.param_valid(pv),
        .param_id(`PARAM_GLIDE),.param_value(glide),.note_on(on),.key_down(held),
        .notes(notes),.base_fcs(bases),.base_periods(base_periods),
        .fcs(fcs),.periods(periods),.busy());

    task sample;
        begin tick=1;@(negedge clk);tick=0;repeat(255) @(negedge clk);end
    endtask
    task configure;
        input [15:0] value;
        begin glide=value;pv=1;@(negedge clk);pv=0;end
    endtask
    task reset_bank;
        begin
            rst=0;held=0;on=0;tick=0;pv=0;
            repeat(4) @(negedge clk);rst=1;configure(48);
        end
    endtask
    task press;
        input integer index;
        input [6:0] note_id;
        input [31:0] expected_fc;
        input [47:0] expected_period;
        input signed [23:0] expected_pitch;
        input [15:0] expected_remaining;
        begin
            // Match allocator timing: NOTE_ON/key_down arrive one clock
            // after sample_tick, before the expression tail scan.
            tick=1;@(negedge clk);tick=0;
            notes[index*7+:7]=note_id;held[index]=1;on[index]=1;
            #1;
            if(fcs[index*32+:32]!==expected_fc || periods[index*48+:48]!==expected_period)
                $fatal(1,"config %0d slot %0d wrong starting frequency/period",OPTIMIZED,index);
            @(negedge clk);on=0;
            if(dut.pitch[index]!==expected_pitch || dut.remaining[index]!==expected_remaining)
                $fatal(1,"config %0d wrong start pitch/duration",OPTIMIZED);
            repeat(254) @(negedge clk);
            if(dut.remaining[index]!==expected_remaining)
                $fatal(1,"advanced during NOTE_ON frame");
        end
    endtask
    task settle;
        input integer index;
        input [31:0] target_fc;
        input [47:0] target_period;
        input integer down;
        reg [31:0] previous;
        reg [47:0] previous_period;
        integer n;
        begin
            previous=fcs[index*32+:32];previous_period=periods[index*48+:48];
            for(n=0;n<48;n=n+1) begin
                sample;
                if((down && (fcs[index*32+:32]>previous || fcs[index*32+:32]<target_fc)) ||
                   (!down && (fcs[index*32+:32]<previous || fcs[index*32+:32]>target_fc)))
                    $fatal(1,"non-monotonic glide frequency");
                if((down && periods[index*48+:48]<previous_period) ||
                   (!down && periods[index*48+:48]>previous_period))
                    $fatal(1,"non-monotonic glide period");
                previous=fcs[index*32+:32];previous_period=periods[index*48+:48];
            end
            if(fcs[index*32+:32]!==target_fc || periods[index*48+:48]!==target_period ||
               dut.remaining[index]!==0) $fatal(1,"glide did not settle on time");
        end
    endtask
    reg signed [23:0] saved_pitch;
    reg [31:0] saved_fc;
    reg [47:0] saved_period;
    integer n,k,l;
    initial begin
        reset_bank;
        press(0,60,fc60,p60,24'sd3932160,0); // first note, glide enabled
        held=0;sample; // release tail remains initialized
        press(1,72,fc72,p72,24'sd4718592,0); // detached note, new slot
        held=0;sample;
        press(1,67,fc67,p67,24'sd4390912,0); // same slot's old tail excluded
        sample;if(fcs[63:32]!==fc67) $fatal(1,"detached note drift");

        reset_bank;
        press(0,60,fc60,p60,24'sd3932160,0);
        press(1,72,fc60,p60,24'sd3932160,48); // overlapping ascending
        settle(1,fc72,p72,0);
        if(fcs[31:0]!==fc60) $fatal(1,"held first voice changed");
        press(2,48,fc72,p72,24'sd4718592,48); // latest held key wins, descending
        settle(2,fc48,p48,1);
        held[2]=0;held[1]=0;sample; // newest notes released, oldest still held
        press(3,67,fc60,p60,24'sd3932160,48);
        settle(3,fc67,p67,0);

        reset_bank;
        press(3,60,fc60,p60,24'sd3932160,0);
        press(0,72,fc60,p60,24'sd3932160,48);
        settle(0,fc72,p72,0);
        press(1,48,fc72,p72,24'sd4718592,48); // recency, not largest slot index
        settle(1,fc48,p48,1);
        held[1]=0;sample;
        press(2,67,fc72,p72,24'sd4718592,48); // fallback to newer slot 0, not slot 3
        settle(2,fc67,p67,1);

        reset_bank;
        press(0,60,fc60,p60,24'sd3932160,0);
        press(1,72,fc60,p60,24'sd3932160,48);
        repeat(12) sample;
        saved_pitch=dut.pitch[1];saved_fc=fcs[63:32];saved_period=periods[95:48];
        if(saved_pitch<=24'sd3932160 || saved_pitch>=24'sd4718592)
            $fatal(1,"chain source is not intermediate pitch");
        press(2,48,saved_fc,saved_period,saved_pitch,48);
        settle(2,fc48,p48,1); // chain from actual pitch, no jump to 72
        configure(0);
        press(3,72,fc72,p72,24'sd4718592,0); // disabled despite held keys
        sample;if(fcs[3*32+:32]!==fc72) $fatal(1,"bypass drift");
        configure(48);held=0;held[3]=1;sample;
        press(3,60,fc60,p60,24'sd3932160,0); // only self held / same-slot reuse

        // Exercise every rank/slot, many more NOTE_ONs than the rank width,
        // and verify the recency permutation never wraps or forms ties.
        configure(0);held=0;
        for(n=0;n<VOICES*3;n=n+1) begin
            press(n%VOICES,60,fc60,p60,24'sd3932160,0);
            if(dut.recency[n%VOICES]!==0) $fatal(1,"new key is not most recent");
            for(k=0;k<VOICES;k=k+1) begin
                if(dut.recency[k]>=VOICES) $fatal(1,"recency range");
                for(l=k+1;l<VOICES;l=l+1)
                    if(dut.recency[k]===dut.recency[l]) $fatal(1,"duplicate recency");
            end
        end
        configure(48);held=0;held[VOICES-1]=1;sample;
        press(0,72,fc60,p60,24'sd3932160,48); // highest slot is valid source
        settle(0,fc72,p72,0);
        done=1;
    end
endmodule

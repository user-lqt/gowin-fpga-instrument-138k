`timescale 1ns/1ps
`include "event_defs.vh"
module tb_audio_timing;
    reg clk=0,rst_n=0,ev=0,pv=0;
    always #5 clk=~clk;
    reg [1:0] kind=1;
    reg [6:0] note=60;
    reg [7:0] velocity=96;
    reg [3:0] pid=0;
    reg [15:0] value=0;
    wire sample_tick,bck,bck_en,frame_start;
    wire mapped_valid,normal_valid,merged_valid,merge_overflow;
    wire [1:0] mapped_type,normal_type,merged_type;
    wire [6:0] mapped_note,normal_note,merged_note;
    wire [7:0] mapped_velocity,normal_velocity,merged_velocity;
    wire ready,pcm_valid,overload,eo,po;
    wire [6:0] voice_count;
    wire signed [23:0] left,right,wet_left,wet_right;
    wire ws,din;
    sample_scheduler #(.CLK_DIV_BCK(2),.CLK_DIV_SAMPLE(256)) scheduler(
        .clk_audio(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .bck(bck),.bck_en(bck_en));
    instrument_link link(.clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
        .command_valid(1'b0),.command(8'd0),.a(8'd0),.b(8'd0),.keys(24'd0),
        .keyboard_valid(ev),.keyboard_type(kind),.keyboard_note(note),.keyboard_velocity(velocity),
        .mapped_valid(mapped_valid),.mapped_type(mapped_type),
        .mapped_note(mapped_note),.mapped_velocity(mapped_velocity),
        .record_valid(1'b0),.record_type(2'd0),.record_note(7'd0),.record_velocity(8'd0),
        .lesson_running(1'b0),.song_mode(1'b0),.score_address(7'd0));
    polyphony_test #(.VOICES(64)) normal_path(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.toggle(1'b0),
        .selection(7'd0),.keys(24'd0),.keyboard_valid(mapped_valid),
        .keyboard_type(mapped_type),.keyboard_note(mapped_note),.keyboard_velocity(mapped_velocity),
        .event_valid(normal_valid),.event_type(normal_type),
        .note_id(normal_note),.velocity(normal_velocity));
    performance_event_merge merge(.clk(clk),.rst_n(rst_n),
        .a_valid(normal_valid),.a_type(normal_type),.a_note(normal_note),.a_velocity(normal_velocity),
        .b_valid(1'b0),.b_type(2'd0),.b_note(7'd0),.b_velocity(8'd0),
        .valid(merged_valid),.kind(merged_type),.note(merged_note),
        .velocity(merged_velocity),.overflow(merge_overflow));
    // Parameters match the actual 64-voice board instance; no shortened envelopes.
    audio_core #(.VOICE_COUNT(64),.ENABLE_EXPRESSION(1),.ENABLE_GUITAR(1),
        .RAM_BODY(1),.SHARE_VOICE_ARITHMETIC(1),.ENABLE_ACCEPTANCE(1),
        .STEREO_OUTPUT(1)) audio(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.acceptance_mode(1'b0),
        .event_valid(merged_valid),.event_type(merged_type),.note_id(merged_note),
        .velocity(merged_velocity),.param_valid(pv),.param_id(pid),.param_value(value),
        .audio_core_valid(pcm_valid),.audio_left(left),.audio_right(right),
        .active_voice_count(voice_count),.engine_ready(ready),
        .overload_flag(overload),.event_overflow(eo),.param_overflow(po));
    audio_delay_fx fx_l(.clk(clk),.rst_n(rst_n),.valid(pcm_valid),
        .param_valid(1'b0),.param_id(4'd0),.param_value(16'd0),
        .audio_in(left),.audio_out(wet_left));
    audio_delay_fx fx_r(.clk(clk),.rst_n(rst_n),.valid(pcm_valid),
        .param_valid(1'b0),.param_id(4'd0),.param_value(16'd0),
        .audio_in(right),.audio_out(wet_right));
    i2s_tx_pcm5102a tx(.clk_audio(clk),.rst_n(rst_n),.bck_in(bck),.bck_en(bck_en),
        .sample_l(wet_left),.sample_r(wet_right),.frame_start(frame_start),
        .o_ws(ws),.o_din(din));
    integer cycle=0,phase_arg,note_arg,instrument_arg,burst_arg;
    integer requested=-1,merged=-1,consumed=-1,allocated=-1;
    integer pcm_nonzero=-1,frame_nonzero=-1,last_pcm=-1,tick_cycle=-1;
    integer monitor=0,events=0,notes=0,peak_queue=0,i;
    integer consumed_cycle[0:127],injected_cycle[0:127];
    always @(posedge clk) begin
        cycle=cycle+1;
        if(rst_n && monitor) begin
            if(sample_tick) tick_cycle=cycle;
            if(merged_valid && merged<0) merged=cycle;
            if(audio.ev_count>peak_queue) peak_queue=audio.ev_count;
            if(sample_tick && (audio.ev_pop || audio.ev_bypass) &&
               audio.selected_type==1) begin
                if(consumed<0) consumed=cycle;
                consumed_cycle[audio.selected_note]=cycle;
                events=events+1;
            end
            if(frame_start && frame_nonzero<0 &&
               ((wet_left!==24'sd0 && (^wet_left)!==1'bx) ||
                (wet_right!==24'sd0 && (^wet_right)!==1'bx)))
                frame_nonzero=cycle;
        end
        #1;
        if(rst_n) begin
            if(eo || po || merge_overflow) $fatal(1,"Queue overflow");
            if(pcm_valid) begin
                if(last_pcm>=0 && cycle-last_pcm!=256) $fatal(1,"PCM cadence changed");
                if(cycle-tick_cycle!=236 && monitor && tick_cycle>=0)
                    $fatal(1,"PCM pipeline latency changed: %0d",cycle-tick_cycle);
                last_pcm=cycle;
                if((^left)===1'bx || (^right)===1'bx) $fatal(1,"Unknown PCM");
                if(monitor && pcm_nonzero<0 && (left!=0 || right!=0)) pcm_nonzero=cycle;
            end
            if(monitor && allocated<0 && audio.a2.voice_note_on!=0) allocated=cycle;
        end
    end
    initial begin
        if(!$value$plusargs("phase=%d",phase_arg)) phase_arg=0;
        if(!$value$plusargs("note=%d",note_arg)) note_arg=60;
        if(!$value$plusargs("instrument=%d",instrument_arg)) instrument_arg=0;
        if(!$value$plusargs("burst=%d",burst_arg)) burst_arg=1;
        for(i=0;i<128;i=i+1) begin consumed_cycle[i]=-1;injected_cycle[i]=-1;end
        repeat(5) @(negedge clk);rst_n=1;
        wait(ready);
        @(negedge clk);
        pid=`PARAM_INSTRUMENT;value=instrument_arg;pv=1;
        @(negedge clk);pv=0;
        repeat(8) begin @(posedge sample_tick);@(negedge clk);end
        // A reproducible scheduler phase; sample_tick is consumed at next edge.
        while(scheduler.cnt!=phase_arg) @(negedge clk);
        monitor=1;
        note=note_arg;ev=1;
        requested=cycle+1;injected_cycle[note]=requested;
        for(i=1;i<burst_arg;i=i+1) begin
            @(negedge clk);
            note=note_arg+i;
            injected_cycle[note]=cycle+1;
        end
        @(negedge clk);ev=0;
        wait(events==burst_arg && frame_nonzero>=0 && allocated>=0);
        repeat(512) @(negedge clk);
        $display("AUDIO,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
            phase_arg,note_arg,instrument_arg,burst_arg,requested,merged,
            consumed,allocated,pcm_nonzero,frame_nonzero,peak_queue,cycle);
        for(i=note_arg;i<note_arg+burst_arg;i=i+1) begin
            if(consumed_cycle[i]<0) $fatal(1,"Missing consumed event");
            $display("QUEUE,%0d,%0d,%0d",i,injected_cycle[i],consumed_cycle[i]);
        end
        $display("PASS audio timing");
        $finish;
    end
    initial begin
        repeat(20000) @(negedge clk);
        $fatal(1,"Audio timing timeout");
    end
endmodule

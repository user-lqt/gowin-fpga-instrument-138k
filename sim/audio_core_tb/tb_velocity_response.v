`timescale 1ns/1ps
`include "event_defs.vh"

module tb_velocity_response #(
    parameter integer SOFT_VELOCITY=32,
    parameter integer HARD_VELOCITY=120,
    parameter CAPTURE_FILE="waveforms/velocity_response.csv"
);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,tick=0,event_valid=0,param_valid=0;
    reg [1:0] event_type=`EVENT_NOTE_ON;
    reg [6:0] note_id=69;
    reg [7:0] velocity=32;
    reg [3:0] param_id=`PARAM_INSTRUMENT;
    reg [15:0] param_value=0;
    wire valid,ready,overload,event_overflow,param_overflow;
    wire signed [23:0] left,right;
    wire [5:0] active;
    integer divider=0,cycle=0,last_tick=0,last_valid=0;
    integer instrument,strike,i,frames=0,trace;
    reg [63:0] energy [0:2];
    reg signed [63:0] pcm;
    reg [31:0] fixed_fc;

    always @(posedge clk) begin
        if(!rst_n) begin divider<=0;tick<=0;end
        else begin divider<=divider==255 ? 0 : divider+1;tick<=divider==255;end
    end
    audio_core #(.VOICE_COUNT(1),.RELEASE_SAMPLES(64)) dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .event_valid(event_valid),.event_type(event_type),
        .note_id(note_id),.velocity(velocity),
        .param_valid(param_valid),.param_id(param_id),.param_value(param_value),
        .audio_core_valid(valid),.audio_left(left),.audio_right(right),
        .active_voice_count(active),.engine_ready(ready),.overload_flag(overload),
        .event_overflow(event_overflow),.param_overflow(param_overflow)
    );
    always @(posedge clk) begin
        cycle=cycle+1;
        if(tick) last_tick=cycle;
        #1;
        if(!rst_n) last_valid=0;
        else if(valid) begin
            if(cycle-last_tick!=75 ||
                (last_valid!=0 && cycle-last_valid!=256))
                $fatal(1,"velocity test sample cadence");
            if((^left)===1'bx || left!==right || overload ||
                event_overflow || param_overflow)
                $fatal(1,"velocity test PCM or queue fault");
            last_valid=cycle;
            frames=frames+1;
        end
    end
    task next_sample;
        begin @(posedge valid);@(negedge clk);end
    endtask
    initial begin
        trace=$fopen(SOFT_VELOCITY==16 ? "waveforms/velocity_endpoints.csv" :
            CAPTURE_FILE,"w");
        if(!trace) $fatal(1,"cannot open velocity capture");
        $fdisplay(trace,"instrument,velocity,index,sample");
        for(instrument=0;instrument<3;instrument=instrument+1) begin
            for(strike=0;strike<3;strike=strike+1) begin
                @(negedge clk);
                rst_n=0;event_valid=0;param_valid=0;
                repeat(4) @(negedge clk);
                rst_n=1;
                wait(ready);
                @(negedge clk);
                param_value=instrument;param_valid=1;
                @(negedge clk);param_valid=0;
                next_sample;
                velocity=strike==0 ? SOFT_VELOCITY : strike==1 ? 80 : HARD_VELOCITY;
                event_valid=1;
                @(negedge clk);event_valid=0;
                repeat(4) next_sample;
                if(active!=1 || dut.a2.voice_note_id[6:0]!=69)
                    $fatal(1,"velocity changed note allocation");
                if(strike==0) fixed_fc=dut.a2.voice_fc[31:0];
                else if(dut.a2.voice_fc[31:0]!==fixed_fc)
                    $fatal(1,"velocity changed fundamental frequency control");
                energy[strike]=0;
                for(i=0;i<128;i=i+1) begin
                    next_sample;
                    pcm=left;
                    energy[strike]=energy[strike]+pcm*pcm;
                    $fdisplay(trace,"%0d,%0d,%0d,%0d",instrument,velocity,i,left);
                end
            end
            if(energy[0]==0 || energy[1]<=energy[0] || energy[2]<=energy[1])
                $fatal(1,"velocity energy ordering t=%0d: %0d/%0d/%0d",
                    instrument,energy[0],energy[1],energy[2]);
            $display("PASS velocity t=%0d: soft/medium/hard %0d/%0d/%0d; pitch unchanged",
                instrument,energy[0],energy[1],energy[2]);
        end
        $fclose(trace);
        $display("VELOCITY BASELINE PASS: %0d valid frames, three timbres",frames);
        $finish;
    end
    initial begin #10000000;$fatal(1,"velocity test timeout");end
endmodule

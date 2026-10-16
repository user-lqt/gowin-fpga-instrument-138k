`timescale 1ns/1ps
module string_math_pair #(
    parameter integer DYNAMIC_PITCH=0
) (
    input wire clk,rst_n,sample_tick,note_on,enabled,
    input wire [31:0] fc,
    input wire [47:0] period_q16,
    input wire [7:0] velocity
);
    wire signed [15:0] reference_wave,shared_wave;
    plucked_string #(.DYNAMIC_PITCH(DYNAMIC_PITCH),.SHARE_ARITHMETIC(0)) reference(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.note_on(note_on),
        .enabled(enabled),.fc(fc),.period_q16(period_q16),.velocity(velocity),
        .wave(reference_wave));
    plucked_string #(.DYNAMIC_PITCH(DYNAMIC_PITCH),.SHARE_ARITHMETIC(1)) optimized(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.note_on(note_on),
        .enabled(enabled),.fc(fc),.period_q16(period_q16),.velocity(velocity),
        .wave(shared_wave));
    integer checks=0;
    always @(negedge clk) if(rst_n) begin
        if(shared_wave!==reference_wave ||
           optimized.pick_level!==reference.pick_level ||
           optimized.dc!==reference.dc ||
           optimized.prior_fractional!==reference.prior_fractional)
            $fatal(1,"shared math mismatch dynamic=%0d check=%0d",DYNAMIC_PITCH,checks);
        if(optimized.ram_write &&
           (optimized.ram_address!==reference.ram_address ||
            optimized.ram_data!==reference.ram_data))
            $fatal(1,"delay write mismatch dynamic=%0d check=%0d",DYNAMIC_PITCH,checks);
        checks=checks+1;
    end
endmodule

module tb_string_shared_math;
    reg clk=0,rst_n=0,sample_tick=0,note_on=0,enabled=1;
    reg [31:0] fc=39370534;
    reg [47:0] period_q16=48'd7149382;
    reg [7:0] velocity=80;
    reg [11:0] divide_input=0;
    wire [11:0] quotient_three,quotient_five;
    integer scenario,frame,cycle;
    always #5 clk=~clk;
    string_math_pair fixed_pair(.*);
    string_math_pair #(.DYNAMIC_PITCH(1)) dynamic_pair(.*);
    string_constant_divide #(.DIVISOR(3)) divider_three(
        .numerator(divide_input),.quotient(quotient_three));
    string_constant_divide #(.DIVISOR(5)) divider_five(
        .numerator(divide_input),.quotient(quotient_five));
    task run_frame;
        input integer clocks;
        begin
            sample_tick=1;
            @(negedge clk);sample_tick=0;note_on=0;
            repeat(clocks-1) @(negedge clk);
        end
    endtask
    initial begin
        for(cycle=0;cycle<4096;cycle=cycle+1) begin
            divide_input=cycle;#1;
            if(quotient_three!==cycle/3 || quotient_five!==cycle/5)
                $fatal(1,"constant divider mismatch input=%0d",cycle);
        end
        repeat(4) @(negedge clk);
        rst_n=1;
        for(scenario=0;scenario<9;scenario=scenario+1) begin
            case(scenario%3)
                0: begin fc=32'd5852465;period_q16=48'd48093320;velocity=16;end
                1: begin fc=32'd39370534;period_q16=48'd7149382;velocity=80;end
                2: begin fc=32'd314964272;period_q16=48'd893673;velocity=127;end
            endcase
            // Exercise saturation, maximum delay and clamped minimum delay.
            if(scenario==6) begin period_q16=48'd160000000;velocity=255;end
            if(scenario==7) begin period_q16=48'd65536;velocity=1;end
            if(scenario==8) velocity=0;
            enabled=1;note_on=1;
            @(negedge clk);note_on=0;
            for(frame=0;frame<200;frame=frame+1) begin
                if(frame==60) period_q16=period_q16+(period_q16>>4);
                if(frame==90) period_q16=period_q16-(period_q16>>3);
                if(frame==110) enabled=0;
                if(frame==120) enabled=1;
                if(frame==145) note_on=1;
                run_frame(scenario<3 ? 256 : 96);
                note_on=0;
            end
        end
        // Fill can end immediately before a sample: no idle rising edge is
        // available to precompute the first playback pick product.
        enabled=1;velocity=127;period_q16=48'd7149382;
        note_on=1;@(negedge clk);note_on=0;
        wait(fixed_pair.optimized.filling && !fixed_pair.optimized.warming);
        wait(!fixed_pair.optimized.filling);
        @(negedge clk);run_frame(256);
        // Follow the pick gain all the way down to its zero endpoint.
        repeat(5000) run_frame(96);
        if(fixed_pair.optimized.pick_level!==0 ||
           dynamic_pair.optimized.pick_level!==0)
            $fatal(1,"pick gain did not terminate");
        rst_n=0;repeat(4) @(negedge clk);rst_n=1;
        repeat(4) run_frame(256);
        $display("STRING SHARED MATH PASS: 4096 divider inputs; fixed/dynamic, 6805 frames including first-playback boundary and zero pick gain, all PCM/state/writes identical");
        $finish;
    end
    initial begin #10000000;$fatal(1,"shared string math timeout");end
endmodule

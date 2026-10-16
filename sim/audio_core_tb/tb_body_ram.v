`timescale 1ns/1ps
module body_ram_pair #(parameter integer LANES=8)(
    input wire clk,rst_n,tick,
    input wire [15:0] on,
    input wire [255:0] inputs,
    input wire [31:0] cycle,frame
);
    wire [LANES*16-1:0] actual,reference;
    guitar_body_ram_bank #(.LANES(LANES)) dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),.note_on(on[LANES-1:0]),
        .string_waves(inputs[LANES*16-1:0]),.waves(actual));
    guitar_body_tone_bank #(.LANES(LANES)) ref_bank(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),.note_on(on[LANES-1:0]),
        .string_waves(inputs[LANES*16-1:0]),.waves(reference));
    genvar v;
    generate for(v=0;v<LANES;v=v+1) begin : checks
        wire [191:0] logical_state=dut.initialized[v] ? dut.state_ram[v] : 192'd0;
        always @(posedge clk) begin
            #1;
            if(rst_n && cycle>=70) begin
                if(actual[v*16+:16] !== reference[v*16+:16] ||
                   dut.tone[v] !== ref_bank.tone[v])
                    $fatal(1,"tone mismatch lanes=%0d frame=%0d cycle=%0d lane=%0d",
                        LANES,frame,cycle,v);
            end
            if(rst_n && cycle>=250 &&
               logical_state !== {ref_bank.x1[v],ref_bank.x2[v],
                   ref_bank.low1[v],ref_bank.low2[v],ref_bank.mid1[v],
                   ref_bank.mid2[v],ref_bank.high1[v],ref_bank.high2[v]})
                $fatal(1,"history mismatch lanes=%0d frame=%0d cycle=%0d lane=%0d",
                    LANES,frame,cycle,v);
            if(rst_n && cycle==250 && dut.step!=0)
                $fatal(1,"body RAM missed filter deadline");
        end
    end endgenerate
endmodule

module tb_body_ram;
    reg clk=0,rst_n=0,tick=0;
    always #5 clk=~clk;
    reg [15:0] on=0;
    reg [255:0] inputs=0;
    reg [31:0] cycle=0,frame=0;
    reg [31:0] random_state=32'hc0174e8d;
    integer l;
    body_ram_pair #(.LANES(1)) one(.*);
    body_ram_pair #(.LANES(2)) two(.*);
    body_ram_pair #(.LANES(3)) three(.*);
    body_ram_pair #(.LANES(4)) four(.*);
    body_ram_pair #(.LANES(5)) five(.*);
    body_ram_pair #(.LANES(7)) seven(.*);
    body_ram_pair #(.LANES(8)) eight(.*);
    body_ram_pair #(.LANES(15)) fifteen(.*);
    body_ram_pair #(.LANES(16)) sixteen(.*);
    initial begin
        repeat(4) @(negedge clk);
        rst_n=1;
        for(frame=0;frame<512;frame=frame+1) begin
            for(l=0;l<16;l=l+1) begin
                random_state={random_state[30:0],random_state[31]^random_state[21]^
                    random_state[1]^random_state[0]};
                inputs[l*16+:16]=random_state[15:0];
            end
            for(cycle=0;cycle<256;cycle=cycle+1) begin
                @(negedge clk);tick=cycle==0;on=0;
                if(frame%29==0 && cycle==1) on=16'hffff;
                if(frame%11==0 && cycle==20) on=16'h1 << (frame%16);
                if(frame%17==0 && cycle==0) on=16'h8000;
                if(frame%19==0 && cycle==7) on=16'h1 << (frame%16);
                if(frame%23==0 && cycle==90) on=16'h1 << (frame%16);
                if(frame%31==0 && cycle==239) on=16'hffff;
                if(frame%37==0 && cycle==255) on=16'hffff;
                if(frame%257==256 && cycle==128) rst_n=0;
                if(frame%257==256 && cycle==132) rst_n=1;
                @(posedge clk);#2;
            end
        end
        $display("BODY RAM PASS: 1/2/3/4/5/7/8/15/16 lanes, 512 frames, 256 clocks/sample; tone exact from clock 70, history exact from clock 250");
        $finish;
    end
endmodule

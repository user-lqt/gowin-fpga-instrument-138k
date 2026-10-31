`timescale 1ns/1ps
module tb_oscillator_state_bank;
    reg clk=0,rst_n=0,tick=0;
    always #5 clk=~clk;
    reg [7:0] on=0;
    reg [255:0] fcs=0;
    reg [15:0] instruments=0;
    reg [63:0] brightnesses=0;
    wire [127:0] waves;
    wire [127:0] reference;
    reg test_passed=0;
    oscillator_state_bank bank(.clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .note_on(on),.fcs(fcs),.instruments(instruments),
        .brightnesses(brightnesses),.waves(waves));
    genvar g;
    generate for(g=0;g<8;g=g+1) begin : scalar
        oscillator #(.ENABLE_TIMBRES(1)) ref_dut(
            .clk(clk),.rst_n(rst_n),.sample_tick(tick),.phase_load(on[g]),
            .fc(fcs[g*32+:32]),.instrument(instruments[g*2+:2]),
            .brightness(brightnesses[g*8+:8]),.wave(reference[g*16+:16]));
    end endgenerate
    integer f,c,gain_mode,i,checks=0;
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        for(gain_mode=0;gain_mode<4;gain_mode=gain_mode+1) begin
            for(i=0;i<8;i=i+1) begin
                fcs[i*32+:32]=i<4 ? 32'd731558*(1<<i)*8 :
                    i==4 ? 32'h19876543 : i==5 ? 32'h29876543 :
                    i==6 ? 32'h39876543 : 32'h49876543;
                instruments[i*2+:2]=gain_mode;
                brightnesses[i*8+:8]=16+i*29;
            end
            for(f=0;f<256;f=f+1) begin
                for(c=0;c<256;c=c+1) begin
                    tick=c==0;
                    on=(f==0 || f==127) && c==1 ? 8'hff : 8'h00;
                    if(c==112 && f>0)
                        for(i=0;i<8;i=i+1)
                            fcs[i*32+:32]=fcs[i*32+:32]+32'd54321;
                    @(negedge clk);
                    if(c==200) begin
                        if(waves!==reference)
                            $fatal(1,"oscillator bank mismatch instrument=%0d frame=%0d actual=%h reference=%h",
                                gain_mode,f,waves,reference);
                        checks=checks+8;
                    end
                end
            end
        end
        test_passed=1;
        $display("PASS oscillator state bank: %0d exact samples, four instruments, eight frequency/brightness lanes",checks);
        $finish;
    end
endmodule

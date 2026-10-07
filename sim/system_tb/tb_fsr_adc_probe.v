`timescale 1ns/1ps
module tb_fsr_adc_probe;
    reg reference=0,reset_button=1,disconnected=0;
    always #10 reference=~reference;
    reg [9:0] pressure=1;
    wire cs_n,sclk,mosi,model_miso;
    wire miso=disconnected ? 1'b1 : model_miso;
    mcp3008_model adc(.cs_n(cs_n),.sclk(sclk),.mosi(mosi),
        .ch0(pressure),.ch1(10'd1023),.ch2(10'd0),.miso(model_miso));
    fsr_adc_probe_top dut (
        .i_clk_in(reference),.i_rst_n(reset_button),.col_in(6'b111111),
        .enc_a(1'b1),.enc_b(1'b1),.enc_sw_n(1'b1),
        .enc2_a(1'b1),.enc2_b(1'b1),.enc2_sw_n(1'b1),.adc_miso(miso),
        .adc_cs_n(cs_n),.adc_sclk(sclk),.adc_mosi(mosi)
    );
    initial begin
        repeat(5) @(negedge reference);reset_button=0;
        wait(dut.display_ready && dut.adc_digits==16'h0001);
        if(dut.vib_digits!=0 || dut.u_adc.sample_channel!=0)
            $fatal(1,"probe neutral calibration/CH0 selection");
        pressure=899;
        wait(dut.adc_digits==16'h0899 && dut.vib_digits==16'h0100);
        pressure=1023;
        wait(dut.adc_digits==16'h1023);
        if(!dut.display_ready) $fatal(1,"real full-scale ADC was rejected");
        @(negedge cs_n);disconnected=1;
        wait(!dut.display_ready);
        repeat(10) @(negedge dut.clk_audio);
        if(dut.adc_digits!=0 || dut.vib_digits!=0)
            $fatal(1,"probe disconnected DOUT not invalidated");
        pressure=1;@(posedge cs_n);disconnected=0;
        wait(dut.display_ready && dut.adc_digits==16'h0001);
        if(dut.vib_digits!=0) $fatal(1,"probe did not recover after DOUT reconnection");
        reset_button=1;repeat(10) @(negedge reference);
        if(dut.display_ready) $fatal(1,"probe reset did not clear readiness");
        $display("PASS CH0-only board probe ADC/VIB digits, valid full-scale, disconnected DOUT invalidation, recovery and reset");
        $finish;
    end
    initial begin #30000000;$fatal(1,"probe timeout");end
endmodule

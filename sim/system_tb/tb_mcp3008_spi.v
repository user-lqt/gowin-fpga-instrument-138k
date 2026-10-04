`timescale 1ns/1ps
module tb_mcp3008_spi;
    reg clk=0,rst_n=0,start=0,miso=0;
    reg [2:0] channel=0;
    wire cs_n,sclk,mosi,busy,done;
    wire [9:0] data;
    mcp3008_spi #(.CLK_DIV(2)) dut(
        .clk(clk),.rst_n(rst_n),.start(start),.channel(channel),.adc_miso(miso),
        .adc_cs_n(cs_n),.adc_sclk(sclk),.adc_mosi(mosi),.busy(busy),.done(done),.adc_data(data));
    always #5 clk=~clk;
    reg [9:0] slave_data;
    integer rises;
    always @(posedge sclk) rises=rises+1;
    always @(negedge sclk or posedge cs_n) begin
        if(cs_n) begin miso<=0;rises<=0;end
        else if(rises==6) miso<=slave_data[9];
        else if(rises>6 && rises<16) miso<=slave_data[15-rises];
        else miso<=0;
    end
    task convert;
        input [2:0] ch; input [9:0] expected;
        begin
            channel=ch;slave_data=expected;rises=0;
            @(negedge clk);start=1;@(negedge clk);start=0;
            wait(done);
            if(data!==expected) $fatal(1,"MCP3008 CH%0d expected %0d got %0d",ch,expected,data);
            if(cs_n!==1 || busy!==0) $fatal(1,"MCP3008 transaction did not finish");
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        convert(0,10'd0);convert(1,10'd512);convert(2,10'd1023);
        $display("PASS MCP3008 mode0 command/null/data alignment and CS timing");$finish;
    end
    initial begin #100000;$fatal(1,"MCP3008 timeout");end
endmodule

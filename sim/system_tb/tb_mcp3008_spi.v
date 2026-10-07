`timescale 1ns/1ps
module tb_mcp3008_spi;
    reg clk=0,rst_n=0,start=0,disconnected=0;
    reg [2:0] channel=0;
    wire cs_n,sclk,mosi,busy,done,valid;
    wire [9:0] data;
    reg slave_miso=1;
    wire miso=disconnected ? 1'b1 : slave_miso;
    mcp3008_spi #(.CLK_DIV(2)) dut(
        .clk(clk),.rst_n(rst_n),.start(start),.channel(channel),.adc_miso(miso),
        .adc_cs_n(cs_n),.adc_sclk(sclk),.adc_mosi(mosi),.busy(busy),
        .done(done),.adc_data(data),.conversion_valid(valid));
    always #5 clk=~clk;
    reg [9:0] slave_data;
    reg [4:0] command;
    integer rises=0,ch;
    always @(negedge cs_n) begin rises=0;command=0;end
    always @(posedge sclk) if(!cs_n) begin
        rises=rises+1;
        if(rises<=5) command={command[3:0],mosi};
        if(rises==5 && command!=={2'b11,channel})
            $fatal(1,"MCP3008 command expected channel %0d got %b",channel,command);
    end
    // Independent slave timing follows datasheet figure 5-1, not DUT counters.
    always @(negedge sclk or posedge cs_n) begin
        if(cs_n || rises<6) slave_miso<=#3 1;
        else if(rises==6) slave_miso<=#3 0;
        else if(rises>=7 && rises<=16) slave_miso<=#3 slave_data[16-rises];
        else slave_miso<=#3 0;
    end
    task convert;
        input [2:0] ch; input [9:0] expected;
        begin
            channel=ch;slave_data=expected;
            @(negedge clk);start=1;@(negedge clk);start=0;
            wait(done);#1;
            if(valid!==!disconnected)
                $fatal(1,"MCP3008 missing null response not rejected");
            if(!disconnected && data!==expected)
                $fatal(1,"MCP3008 CH%0d expected %0d got %0d",ch,expected,data);
            if(cs_n!==1 || busy!==0 || rises!=17)
                $fatal(1,"MCP3008 must finish after 17 clocks");
            @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        for(ch=0;ch<8;ch=ch+1) begin
            convert(ch,0);convert(ch,1);convert(ch,2);
            convert(ch,341);convert(ch,682);convert(ch,899);
            convert(ch,1022);convert(ch,1023);
        end
        disconnected=1;convert(0,0);convert(1,899);
        disconnected=0;convert(0,899);
        $display("PASS MCP3008 datasheet 17-clock timing, all 8 channel commands, odd/even/full-scale codes, missing DOUT null rejection and recovery");
        $finish;
    end
    initial begin #100000;$fatal(1,"MCP3008 timeout");end
endmodule

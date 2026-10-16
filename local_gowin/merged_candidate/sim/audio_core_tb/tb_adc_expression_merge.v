`timescale 1ns/1ps
`include "event_defs.vh"
module tb_adc_expression_merge;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg [7:0] divider=0;
    always @(posedge clk) divider<=rst_n ? divider+8'd1 : 8'd0;
    wire tick=divider==8'hff;
    reg [9:0] pressure=1,x=512,y=512;
    reg disconnected=0,miso_bit=0;
    wire cs,sck,mosi;
    wire miso=disconnected ? 1'b1 : miso_bit;
    integer edges=0,expected_channel=0;
    reg [4:0] command;
    reg [9:0] response;
    always @(negedge cs) begin edges=0;command=0;miso_bit=0;end
    always @(posedge sck) begin
        if(edges<5) command={command[3:0],mosi};
        edges=edges+1;
        if(edges==5) begin
            if(command!==5'b11000+expected_channel)
                $fatal(1,"ADC round-robin command %b, expected CH%d",command,expected_channel);
            case(expected_channel)
                0:response=pressure;1:response=x;2:response=y;
            endcase
            expected_channel=expected_channel==2 ? 0 : expected_channel+1;
        end
    end
    always @(negedge sck) if(!cs) begin
        if(edges==6) miso_bit=0;
        else if(edges>=7 && edges<=16) miso_bit=response[16-edges];
    end
    wire valid,error;
    wire [2:0] channel;
    wire [9:0] raw0,raw1,raw2;
    mcp3008_sampler #(.CLK_DIV(2),.CHANNEL_COUNT(3),.SAMPLE_DIV(256)) adc(
        .clk(clk),.rst_n(rst_n),.adc_miso(miso),.adc_cs_n(cs),.adc_sclk(sck),
        .adc_mosi(mosi),.sample_valid(valid),.sample_error(error),
        .sample_channel(channel),.ch0_data(raw0),.ch1_data(raw1),.ch2_data(raw2));
    wire fv,jv,ready,pv,overflow;
    wire [3:0] fid,jid,pid;
    wire [15:0] fvalue,jvalue,value;
    fsr_expression_control fsr(.clk(clk),.rst_n(rst_n),.sample_valid(valid),
        .sample_error(error),.sample_channel(channel),.ch0_data(raw0),
        .param_valid(fv),.param_id(fid),.param_value(fvalue),.sensor_ready(ready));
    joystick_control joystick(.clk(clk),.rst_n(rst_n),.sample_valid(valid),
        .sample_error(error),.sample_channel(channel),.ch1_x(raw1),.ch2_y(raw2),
        .param_valid(jv),.param_id(jid),.param_value(jvalue));
    encoder_param_queue queue(.clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .a_valid(1'b0),.a_id(4'd0),.a_value(16'd0),
        .b_valid(1'b0),.b_id(4'd0),.b_value(16'd0),
        .c_valid(jv && jid==`PARAM_PITCH_BEND),.c_id(jid),.c_value(jvalue),
        .d_valid(fv),.d_id(fid),.d_value(fvalue),
        .valid(pv),.id(pid),.value(value),.overflow(overflow));
    integer bend=-1,depth=-1,errors=0;
    always @(posedge clk) begin
        if(pv && pid==`PARAM_PITCH_BEND) bend=$signed(value);
        if(pv && pid==`PARAM_MODULATION) depth=value;
        if(error) errors=errors+1;
        if(overflow) $fatal(1,"expression parameter overflow");
    end
    task wait_samples;
        input integer count;
        integer i;
        begin for(i=0;i<count;i=i+1) begin @(posedge tick);@(negedge clk);end end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        wait_samples(100);
        if(bend!=0 || depth!=0 || !ready) $fatal(1,"center/released");
        pressure=899;x=1023;y=0;wait_samples(600);
        if(bend!=8191 || depth!=65535) $fatal(1,"full pressure + X positive");
        pressure=1;y=1023;wait_samples(600);
        if(depth!=0 || bend!=8191) $fatal(1,"Y overwrote released FSR");
        x=0;wait_samples(100);
        if(bend!=-8192) $fatal(1,"negative bend");
        disconnected=1;wait_samples(500);
        if(errors==0 || ready || depth!=0 || bend!=0) $fatal(1,"SPI fault recovery");
        disconnected=0;x=512;y=512;wait_samples(100);
        if(!ready || depth!=0 || bend!=0) $fatal(1,"reconnected");
        $display("PASS merged ADC three-channel SPI, FSR ownership, bend endpoints and error recovery");
        $finish;
    end
    initial begin #10000000;$fatal(1,"timeout");end
endmodule

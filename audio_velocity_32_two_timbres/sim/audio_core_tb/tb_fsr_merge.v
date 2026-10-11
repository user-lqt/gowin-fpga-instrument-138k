`timescale 1ns/1ps
module tb_fsr_merge;
 reg clk=0,rst=0,tick=0;
 always #5 clk=~clk;
 integer div=0;
 always @(posedge clk) begin
 if(!rst) begin div<=0;tick<=0;end
 else begin div<=div==255 ? 0 : div+1;tick<=div==255;end end
 reg [9:0] pressure=1;reg disconnected=0,miso_bit=0;
 wire cs,sck,mosi;wire miso=disconnected ? 1'b1 : miso_bit;
 integer rises=0;reg [4:0] command=0;
 always @(negedge cs) begin rises=0;command=0;miso_bit=0;end
 always @(posedge sck) begin
 if(rises<5) command={command[3:0],mosi};
 rises=rises+1;
 if(rises==5 && command!=5'b11000) $fatal(1,"CH0 command");end
 // Independent slave timing: null after clock6, B9 after clock7.
 always @(negedge sck) if(!cs) begin
 if(rises==6) miso_bit=0;
 else if(rises>=7 && rises<=16) miso_bit=pressure[16-rises];
 end
 wire sv,se;wire [2:0] channel;wire [9:0] raw;
 mcp3008_sampler #(.CLK_DIV(2),.CHANNEL_COUNT(1),.SAMPLE_DIV(256)) adc(
 .clk(clk),.rst_n(rst),.adc_miso(miso),.adc_cs_n(cs),.adc_sclk(sck),.adc_mosi(mosi),
 .busy(),.sample_valid(sv),.sample_error(se),.sample_channel(channel),.ch0_data(raw),.ch1_data(),.ch2_data());
 wire fv;wire [3:0] fid;wire [15:0] depth;wire ready;
 fsr_expression_control fsr(.clk(clk),.rst_n(rst),.sample_valid(sv),.sample_error(se),
 .sample_channel(channel),.ch0_data(raw),.param_valid(fv),.param_id(fid),.param_value(depth),
 .filtered_value(),.modulation_value(),.sensor_ready(ready));
 wire pv,overflow;wire [3:0] pid;wire [15:0] value;
 encoder_param_queue queue(.clk(clk),.rst_n(rst),.sample_tick(tick),
 .a_valid(1'b0),.b_valid(1'b0),.c_valid(fv),.a_id(4'd0),.b_id(4'd0),.c_id(fid),
 .a_value(16'd0),.b_value(16'd0),.c_value(depth),.valid(pv),.id(pid),.value(value),.overflow(overflow));
 wire signed [23:0] pitch;
 pitch_vibrato vibrato(.clk(clk),.rst_n(rst),.sample_tick(tick),.param_valid(pv),
 .param_id(pid),.param_value(value),.pitch_offset(pitch));
 integer last=-1,errors=0;
 always @(posedge clk) begin
 if(pv) last=value;
 if(se) errors=errors+1;
 if(overflow) $fatal(1,"parameter overflow");end
 task wait_samples;input integer n;integer i;
 begin for(i=0;i<n;i=i+1) begin @(posedge tick);@(negedge clk);end end endtask
 initial begin
 repeat(4) @(negedge clk);rst=1;
 wait_samples(40);if(raw!=1 || last!=0 || !ready) $fatal(1,"released");
 pressure=450;wait_samples(150);
 if(raw!=450 || last<30000 || last>35000) $fatal(1,"middle pressure %d",last);
 pressure=899;wait_samples(150);
 if(raw!=899 || last<65000) $fatal(1,"full pressure");
 wait_samples(512);if(pitch==0) $fatal(1,"no vibrato");
 pressure=1023;wait_samples(60);if(raw!=1023 || last!=65535) $fatal(1,"valid full scale");
 disconnected=1;wait_samples(350);
 if(errors==0 || ready || last!=0 || pitch!=0) $fatal(1,"invalid data did not revoke vibrato");
 disconnected=0;pressure=1;wait_samples(60);
 if(!ready || raw!=1 || last!=0) $fatal(1,"recovery");
 $display("PASS FSR CH0 SPI, pressure mapping, queue to vibrato, invalid data mute and recovery");$finish;
 end
 initial begin #10000000;$fatal(1,"timeout");end
endmodule

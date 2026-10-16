//21.33ms window:512 bins, min/max of two samples. Frozen ping-pong RAM.
module waveform_buffer(input wire audio_clk,audio_rst_n,valid,
 input wire signed [15:0] sample,
 input wire pixel_clk,pixel_rst_n,frame_start,input wire [8:0] read_address,
 output reg signed [15:0] minimum,maximum,output reg ready);
 reg signed [15:0] low_ram[0:1023],high_ram[0:1023];
 reg bank,half,waiting,request;reg [8:0] index;reg signed [15:0] first;
 reg acknowledge,ack_meta,ack_sync,req_meta,req_sync,read_bank;
 always @(posedge audio_clk) if(audio_rst_n && valid && !waiting && half) begin
 low_ram[{bank,index}]<=sample<first ? sample : first;
 high_ram[{bank,index}]<=sample>first ? sample : first;end
 always @(posedge audio_clk or negedge audio_rst_n) begin
 if(!audio_rst_n) begin bank<=1;half<=0;waiting<=0;request<=0;index<=0;first<=0;ack_meta<=0;ack_sync<=0;end
 else begin ack_meta<=acknowledge;ack_sync<=ack_meta;
 if(waiting) begin if(ack_sync==request) begin waiting<=0;bank<=~bank;index<=0;end end
 else if(valid) begin
 if(!half) begin first<=sample;half<=1;end
 else begin half<=0;if(index==511) begin request<=~request;waiting<=1;end else index<=index+1'b1;end
 end end end
 always @(posedge pixel_clk) begin
 minimum<=low_ram[{read_bank,read_address}];maximum<=high_ram[{read_bank,read_address}];end
 always @(posedge pixel_clk or negedge pixel_rst_n) begin
 if(!pixel_rst_n) begin req_meta<=0;req_sync<=0;acknowledge<=0;read_bank<=0;ready<=0;end
 else begin req_meta<=request;req_sync<=req_meta;
 if(frame_start && req_sync!=acknowledge) begin read_bank<=~read_bank;acknowledge<=req_sync;ready<=1;end
 end end
endmodule

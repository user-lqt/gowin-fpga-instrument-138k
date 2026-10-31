//21.33ms window:512 bins, min/max of two samples. Rising-zero trigger;
// automatic capture after 2048 samples also handles silence and DC.
module waveform_buffer(input wire audio_clk,audio_rst_n,valid,
 input wire signed [15:0] sample,
 input wire pixel_clk,pixel_rst_n,frame_start,input wire [8:0] read_address,
 output reg signed [15:0] minimum,maximum,output reg ready,
 output reg [3:0] scale_shift);
 reg signed [15:0] low_ram[0:1023],high_ram[0:1023];
 reg bank,half,waiting,request;reg [8:0] index;reg signed [15:0] first;
 reg armed;
 reg signed [15:0] previous;
 reg [11:0] trigger_wait;
 reg [15:0] capture_peak;
 reg [3:0] held_shift,published_shift,recovery_shift;
 reg [1:0] decay_count;
 reg scale_valid;
 wire [15:0] magnitude=sample[15] ? -sample : sample;
 wire [15:0] next_peak=magnitude>capture_peak ? magnitude : capture_peak;
 function [3:0] needed_shift;
 input [15:0] peak;
 integer n;
 begin
 // A small display-only floor avoids expanding silence/LSB noise.
 needed_shift=2;
 for(n=0;n<10;n=n+1)
 if(n>=2 && peak>(32'd28<<n)) needed_shift=n+1;
 end endfunction
 wire [3:0] next_shift=needed_shift(next_peak);
 wire [3:0] recovery_max=decay_count==0 || next_shift>recovery_shift ?
     next_shift : recovery_shift;
 wire trigger_now=(previous<0 && sample>=0) || trigger_wait==2047;
 reg acknowledge,ack_meta,ack_sync,req_meta,req_sync,read_bank;
 always @(posedge audio_clk) if(audio_rst_n && valid && !waiting && half) begin
 low_ram[{bank,index}]<=sample<first ? sample : first;
 high_ram[{bank,index}]<=sample>first ? sample : first;end
 always @(posedge audio_clk or negedge audio_rst_n) begin
 if(!audio_rst_n) begin bank<=1;half<=0;waiting<=0;request<=0;index<=0;first<=0;ack_meta<=0;ack_sync<=0;
 armed<=1;previous<=0;trigger_wait<=0;capture_peak<=0;
 held_shift<=10;published_shift<=10;decay_count<=0;recovery_shift<=10;scale_valid<=0;end
 else begin ack_meta<=acknowledge;ack_sync<=ack_meta;
 if(valid) previous<=sample;
 if(waiting) begin if(ack_sync==request) begin waiting<=0;bank<=~bank;index<=0;armed<=1;trigger_wait<=0;end end
 else if(valid) begin
 if(armed) begin
 if(trigger_now) begin armed<=0;first<=sample;half<=1;capture_peak<=magnitude;end
 else trigger_wait<=trigger_wait+1'b1;
 end else begin
 capture_peak<=next_peak;
 if(!half) begin first<=sample;half<=1;end
 else begin half<=0;if(index==511) begin
 request<=~request;waiting<=1;
 // First capture and range expansion are immediate. Contract only after
 // four complete captures, retaining their largest required range.
 // The published scale is held with its RAM bank until acknowledgement.
 scale_valid<=1;
 if(!scale_valid || next_shift>=held_shift) begin
 held_shift<=next_shift;published_shift<=next_shift;decay_count<=0;
 end else if(decay_count==3) begin
 held_shift<=recovery_max;published_shift<=recovery_max;decay_count<=0;
 end else begin published_shift<=held_shift;recovery_shift<=recovery_max;
 decay_count<=decay_count+1'b1;end
 end else index<=index+1'b1;end
 end
 end end end
 always @(posedge pixel_clk) begin
 minimum<=low_ram[{read_bank,read_address}];maximum<=high_ram[{read_bank,read_address}];end
 always @(posedge pixel_clk or negedge pixel_rst_n) begin
 if(!pixel_rst_n) begin req_meta<=0;req_sync<=0;acknowledge<=0;read_bank<=0;ready<=0;scale_shift<=10;end
 else begin req_meta<=request;req_sync<=req_meta;
 if(frame_start && req_sync!=acknowledge) begin read_bank<=~read_bank;acknowledge<=req_sync;ready<=1;scale_shift<=published_shift;end
 end end
endmodule

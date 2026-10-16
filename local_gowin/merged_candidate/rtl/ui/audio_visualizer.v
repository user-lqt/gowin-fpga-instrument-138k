// Display-only analyzer. Fs=48kHz, rectangular 512-sample DFT, 16 selected bins.
// One shared sample*coefficient multiplier, 32 clocks/sample (256 available).
// XY uses mono x[n] versus x[n-24], NOT stereo phase correlation.
module audio_visualizer(
 input wire audio_clk,audio_rst_n,valid,
 input wire signed [15:0] sample,
 output reg [127:0] spectrum,
 output reg [3:0] gain_shift,
 input wire pixel_clk,pixel_rst_n,frame_start,
 input wire [13:0] xy_address,
 output reg xy_hit,output reg xy_ready);
 function [8:0] frequency_bin;
 input [3:0] n;
 begin case(n)
 0:frequency_bin=1;1:frequency_bin=2;2:frequency_bin=3;3:frequency_bin=4;
 4:frequency_bin=6;5:frequency_bin=8;6:frequency_bin=11;7:frequency_bin=15;
 8:frequency_bin=21;9:frequency_bin=29;10:frequency_bin=40;11:frequency_bin=55;
 12:frequency_bin=76;13:frequency_bin=105;14:frequency_bin=145;15:frequency_bin=200;
 endcase end
 endfunction
 function signed [7:0] sine;
 input [4:0] p;
 begin case(p)
 0,16:sine=0;1,15:sine=25;2,14:sine=49;3,13:sine=71;
 4,12:sine=90;5,11:sine=106;6,10:sine=117;7,9:sine=125;8:sine=127;
 17,31:sine=-25;18,30:sine=-49;19,29:sine=-71;20,28:sine=-90;
 21,27:sine=-106;22,26:sine=-117;23,25:sine=-125;24:sine=-127;
 endcase end
 endfunction
 function [7:0] log_height;
 input [33:0] m;integer j;reg [7:0] height;
 begin
 height=0;
 // Approximate logarithmic display; no calibrated dB claim.
 for(j=14;j<30;j=j+1) if(m[j]) height=(j-13)*8;
 if(|m[33:30]) height=120;
 log_height=height>120 ? 120 : height;
 end endfunction
 reg [8:0] phase[0:15];
 reg signed [31:0] accum_i[0:15],accum_q[0:15];
 reg [127:0] pending_levels;
 reg [8:0] sample_index;
 reg [4:0] cursor;
 reg busy;
 reg signed [15:0] held_sample;
 reg signed [32:0] final_i;
 wire [3:0] band=cursor[4:1];
 wire [4:0] angle=phase[band][8:4]+(cursor[0] ? 5'd0 : 5'd8);
 wire signed [23:0] product=held_sample*sine(angle);
 wire signed [32:0] sum=$signed(cursor[0] ? accum_q[band] : accum_i[band])+$signed(product);
 wire [32:0] abs_i=final_i[32] ? -final_i : final_i;
 wire [32:0] abs_q=sum[32] ? -sum : sum;
 wire [33:0] magnitude={1'b0,abs_i}+{1'b0,abs_q};
 integer k;
 reg [15:0] display_peak;
 reg [8:0] peak_count;
 wire [15:0] absolute_sample=sample[15] ? -sample : sample;
 integer gain_index;
 always @(posedge audio_clk or negedge audio_rst_n) begin
 if(!audio_rst_n) begin gain_shift<=4;display_peak<=0;peak_count<=0;end
 else if(valid) begin
 if(peak_count==511) begin
 gain_shift<=1;
 for(gain_index=1;gain_index<11;gain_index=gain_index+1)
 if((display_peak>absolute_sample ? display_peak : absolute_sample)>(16'd48<<gain_index)) gain_shift<=gain_index+1;
 display_peak<=0;
 end else if(absolute_sample>display_peak) display_peak<=absolute_sample;
 peak_count<=peak_count+1'b1;
 end end
 always @(posedge audio_clk or negedge audio_rst_n) begin
 if(!audio_rst_n) begin
 spectrum<=0;pending_levels<=0;sample_index<=0;cursor<=0;busy<=0;held_sample<=0;final_i<=0;
 for(k=0;k<16;k=k+1) begin phase[k]<=0;accum_i[k]<=0;accum_q[k]<=0;end
 end else begin
 if(valid && !busy) begin held_sample<=sample;cursor<=0;busy<=1;end
 else if(busy) begin
 if(!cursor[0]) begin
 final_i<=sum;accum_i[band]<=sample_index==511 ? 0 : sum[31:0];
 end else begin
 accum_q[band]<=sample_index==511 ? 0 : sum[31:0];
 phase[band]<=sample_index==511 ? 0 : phase[band]+frequency_bin(band);
 if(sample_index==511) pending_levels[band*8+:8]<=log_height(magnitude);
 end
 if(cursor==31) begin
 busy<=0;sample_index<=sample_index+1'b1;
 if(sample_index==511) spectrum<={log_height(magnitude),pending_levels[119:0]};
 end else cursor<=cursor+1'b1;
 end
 end end

 // Two 128x128 bitmaps: clear/write back bank while pixel domain reads front.
 reg point_ram[0:32767];
 reg write_bank,clearing,waiting,request;
 reg [13:0] clear_index;
 reg [9:0] point_count;
 reg acknowledge,ack_meta,ack_sync,req_meta,req_sync,read_bank;
 reg signed [15:0] history[0:23];
 reg [4:0] delay_index,filled;
 function [6:0] coordinate;
 input signed [15:0] s;reg signed [16:0] value;
 begin
 value=17'sd64+($signed(s)>>>gain_shift);
 if(value<1) coordinate=1;
 else if(value>126) coordinate=126;
 else coordinate=value[6:0];
 end endfunction
 wire [6:0] x=coordinate(sample),y=coordinate(history[delay_index]);
 always @(posedge audio_clk) begin
 if(audio_rst_n) begin
 if(clearing) point_ram[{write_bank,clear_index}]<=0;
 else if(valid && !waiting && filled==24) point_ram[{write_bank,y,x}]<=1;
 if(valid) history[delay_index]<=sample;
 end end
 always @(posedge audio_clk or negedge audio_rst_n) begin
 if(!audio_rst_n) begin
 write_bank<=1;clearing<=1;waiting<=0;request<=0;clear_index<=0;point_count<=0;
 ack_meta<=0;ack_sync<=0;delay_index<=0;filled<=0;
 end else begin
 ack_meta<=acknowledge;ack_sync<=ack_meta;
 if(valid) begin
 delay_index<=delay_index==5'd23 ? 5'd0 : delay_index+5'd1;
 if(filled<5'd24) filled<=filled+5'd1;
 end
 if(clearing) begin
 if(clear_index==16383) begin clearing<=0;clear_index<=0;point_count<=0;end
 else clear_index<=clear_index+1'b1;
 end else if(waiting) begin
 if(ack_sync==request) begin waiting<=0;write_bank<=~write_bank;clearing<=1;end
 end else if(valid && filled==24) begin
 if(point_count==1023) begin waiting<=1;request<=~request;end
 else point_count<=point_count+1'b1;
 end
 end end
 always @(posedge pixel_clk) xy_hit<=point_ram[{read_bank,xy_address}];
 always @(posedge pixel_clk or negedge pixel_rst_n) begin
 if(!pixel_rst_n) begin read_bank<=0;req_meta<=0;req_sync<=0;acknowledge<=0;xy_ready<=0;end
 else begin
 req_meta<=request;req_sync<=req_meta;
 if(frame_start && req_sync!=acknowledge) begin
 read_bank<=~read_bank;acknowledge<=req_sync;xy_ready<=1;
 end
 end end
endmodule

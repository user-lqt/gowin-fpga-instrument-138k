// Passive 48 kHz tap. No ready/backpressure connection to the audio path.
// 16384-sample periodic Hann, 1024-sample hop, scaled FFT, relative magnitude.
module spectral_analyzer #(parameter COMPACT_MAP=0)(
 input wire clk,rst_n,valid,input wire signed [15:0] sample,
 output reg [511:0] levels,peaks,
 output reg [15:0] peak_sample,rms_sample,
 output reg clipped,overrun,output reg [15:0] frame_number,
 input wire pixel_clk,pixel_rst_n,pixel_frame_start,
 input wire [8:0] trace_address,output reg [7:0] trace_level,
 output reg trace_ready,
 input wire [5:0] summary_address,output reg [15:0] summary_data,
 output reg [49:0] summary_status,
 output wire screen_frame_begin,screen_frame_done,
 output reg screen_bin_valid,output reg [12:0] screen_bin_index,
 output reg [7:0] screen_bin_level);
 assign screen_frame_begin=state==RESET_FFT;
 assign screen_frame_done=state==PUBLISH;
 localparam N=16384;
 (* syn_ramstyle="block_ram" *) reg [15:0] capture[0:N-1];
 reg [13:0] write_address,capture_count;
 reg capture_full;
 reg [9:0] hop;
 reg [15:0] local_peak;
 reg local_clip;
 reg [43:0] energy;
 wire [15:0] absolute_sample=sample[15] ? -sample : sample;
 wire signed [31:0] sample_square=sample*sample;
 wire [43:0] next_energy=energy+{12'd0,sample_square};
 reg sqrt_busy;
 reg [3:0] sqrt_step;
 reg [31:0] sqrt_input;
 reg [15:0] sqrt_root;
 reg [17:0] sqrt_remainder;
 wire [17:0] sqrt_pair={sqrt_remainder[15:0],sqrt_input[31:30]};
 wire [17:0] sqrt_trial={sqrt_root,2'b01};
 wire sqrt_bit=sqrt_pair>=sqrt_trial;
 wire [15:0] sqrt_next={sqrt_root[14:0],sqrt_bit};
 // Exact restoring integer square root; one shared step instead of 16
 // cascaded subtract/compare networks. No audio-path connection.
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
 sqrt_busy<=0;sqrt_step<=0;sqrt_input<=0;sqrt_root<=0;
 sqrt_remainder<=0;rms_sample<=0;
 end else if(valid && hop==1023) begin
 sqrt_busy<=1;sqrt_step<=0;sqrt_input<=next_energy[41:10];
 sqrt_root<=0;sqrt_remainder<=0;
 end else if(sqrt_busy) begin
 sqrt_input<={sqrt_input[29:0],2'b00};
 sqrt_remainder<=sqrt_bit ? sqrt_pair-sqrt_trial : sqrt_pair;
 sqrt_root<=sqrt_next;
 if(sqrt_step==15) begin rms_sample<=sqrt_next;sqrt_busy<=0;end
 else sqrt_step<=sqrt_step+1'b1;
 end
 end
 reg processing;
 reg [2:0] state;
 localparam IDLE=0,RESET_FFT=1,READ=2,DRAIN=3,PUBLISH=4;
 reg [13:0] start_address,read_index;
 reg [14:0] issued;
 reg [15:0] drain_count;
 wire hop_due=valid && (capture_full ? hop==1023 : capture_count==16383);
 reg [15:0] capture_data;
 wire [13:0] read_address=start_address+read_index;
 wire [13:0] hann_address=read_index[13] ? (14'd0-read_index) : read_index;
 wire [15:0] hann_rom_value;
 reg hann_center;
 always @(posedge clk) hann_center<=read_index==8192;
 wire [15:0] hann_value=hann_center ? 16'd32767 : hann_rom_value;
 spectral_hann_rom u_hann(.clk(clk),.address(hann_address[12:0]),.value(hann_rom_value));
 reg read_valid,window_valid;
 reg signed [31:0] window_product;
 wire [15:0] fft_re,fft_im;
 wire fft_valid;
 spectral_fft16384 u_fft(.clock(clk),.reset(!rst_n || state==RESET_FFT),
 .di_en(window_valid),.di_re(window_product[30:15]),.di_im(16'd0),
 .do_en(fft_valid),.do_re(fft_re),.do_im(fft_im));
 always @(posedge clk) begin
 if(valid) capture[write_address]<=sample;
 capture_data<=capture[read_address];
 window_product<=$signed(capture_data)*$signed({1'b0,hann_value});
 end
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
 write_address<=0;capture_count<=0;capture_full<=0;hop<=0;
 local_peak<=0;energy<=0;peak_sample<=0;clipped<=0;local_clip<=0;
 end else if(valid) begin
 write_address<=write_address+1'b1;
 if(!capture_full) begin
 if(capture_count==16383) capture_full<=1;
 else capture_count<=capture_count+1'b1;
 end
 hop<=hop+1'b1;
 if(absolute_sample>=32760) local_clip<=1;
 if(hop==1023) begin
 peak_sample<=local_peak>absolute_sample ? local_peak : absolute_sample;
 local_peak<=0;energy<=0;clipped<=local_clip || absolute_sample>=32760;local_clip<=0;
 end else begin
 if(absolute_sample>local_peak) local_peak<=absolute_sample;
 energy<=next_energy;
 end
 end
 end
 // Synchronous ROM/capture read followed by one window-product register.
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
 state<=IDLE;processing<=0;start_address<=0;read_index<=0;issued<=0;
 read_valid<=0;window_valid<=0;drain_count<=0;overrun<=0;
 end else begin
 read_valid<=state==READ;window_valid<=read_valid;
 if(hop_due && processing) overrun<=1;
 case(state)
 IDLE:if(hop_due) begin
 processing<=1;start_address<=write_address+1'b1;
 read_index<=0;issued<=0;state<=RESET_FFT;
 end
 RESET_FFT:state<=READ;
 READ:begin
 if(issued==16383) begin state<=DRAIN;drain_count<=0;end
 else begin issued<=issued+1'b1;read_index<=read_index+1'b1;end
 end
 DRAIN:begin
 drain_count<=drain_count+1'b1;
 if(drain_count==20000) state<=PUBLISH;
 end
 PUBLISH:begin processing<=0;state<=IDLE;end
 default:state<=IDLE;
 endcase
 end end
 function [7:0] log_height;
 input [16:0] magnitude;
 integer j;reg [7:0] result;
 begin
 result=0;
 for(j=0;j<16;j=j+1)
 if(magnitude>=(17'd1<<j)) begin
 result=j*8;
 if(j>=3) result=result+((magnitude>>(j-3))&7);
 end
 log_height=result>120 ? 120 : result;
 end endfunction
 reg [13:0] output_index;
 wire [13:0] bin;
 genvar bit_index;
 generate for(bit_index=0;bit_index<14;bit_index=bit_index+1) begin:reverse
 assign bin[bit_index]=output_index[13-bit_index];
 end endgenerate
 wire [15:0] abs_re=fft_re[15] ? -fft_re : fft_re;
 wire [15:0] abs_im=fft_im[15] ? -fft_im : fft_im;
 wire [16:0] magnitude={1'b0,abs_re}+{1'b0,abs_im};
 wire [5:0] bin_band;
 wire [8:0] bin_trace;
 spectral_band_compact u_band(.clk(clk),.address(bin[12:0]),.value(bin_band));
 generate if(COMPACT_MAP) begin:compact_map
 spectral_trace_compact u_trace_map(.clk(clk),.address(bin[12:0]),.value(bin_trace));
 end else begin:full_map
 spectral_trace_rom u_trace_map(.clk(clk),.address(bin[12:0]),.value(bin_trace));
 end endgenerate
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin screen_bin_valid<=0;screen_bin_index<=0;screen_bin_level<=0;end
 else begin screen_bin_valid<=fft_valid && !bin[13];
 screen_bin_index<=bin[12:0];screen_bin_level<=log_height(magnitude);end
 end
 reg selected_valid;
 reg [7:0] selected_level;
 reg [7:0] band_work[0:63],trace_work[0:511];
 reg [8:0] clear_index;
 reg clearing;
 integer i;
 // Clear a small display summary while FFT is being filled, never a full frame RAM.
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin output_index<=0;selected_valid<=0;selected_level<=0;end
 else begin
 if(state==RESET_FFT) output_index<=0;
 else if(fft_valid) output_index<=output_index+1'b1;
 selected_valid<=fft_valid && !bin[13] && bin>=14'd14 && bin<=14'd6827;
 selected_level<=log_height(magnitude);
 end end
 always @(posedge clk) begin
 if(state==RESET_FFT) begin clearing<=1;clear_index<=0;end
 else if(clearing) begin
 trace_work[clear_index]<=0;
 if(clear_index<64) band_work[clear_index[5:0]]<=0;
 if(clear_index==511) clearing<=0;else clear_index<=clear_index+1'b1;
 end else if(selected_valid) begin
 if(selected_level>band_work[bin_band]) band_work[bin_band]<=selected_level;
 if(selected_level>trace_work[bin_trace]) trace_work[bin_trace]<=selected_level;
 end
 end
 reg write_bank,request,waiting;
 reg [511:0] pending_levels,pending_peaks;
 reg [8:0] copy_index;
 reg copying;
 reg acknowledge,ack_meta,ack_sync;
 (* syn_ramstyle="block_ram" *) reg [15:0] summary_memory[0:127];
 (* syn_ramstyle="distributed_ram" *) reg [7:0] peak_history[0:63];
 reg [49:0] held_summary_status;
 reg peak_history_valid;
 wire [7:0] previous_peak=peak_history_valid ? peak_history[copy_index[5:0]] : 8'd0;
 wire [7:0] next_peak=band_work[copy_index[5:0]]>previous_peak ?
 band_work[copy_index[5:0]] : previous_peak!=0 ? previous_peak-8'd1 : 8'd0;
 always @(posedge clk) if(copying && copy_index<64) begin
 summary_memory[{write_bank,copy_index[5:0]}]<={next_peak,band_work[copy_index[5:0]]};
 peak_history[copy_index[5:0]]<=next_peak;
 end
 (* syn_ramstyle="block_ram" *) reg [7:0] trace_memory[0:1023];
 always @(posedge clk) if(copying)
 trace_memory[{write_bank,copy_index}]<=trace_work[copy_index];
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
 write_bank<=1;request<=0;waiting<=0;copy_index<=0;copying<=0;
 ack_meta<=0;ack_sync<=0;levels<=0;peaks<=0;pending_levels<=0;pending_peaks<=0;frame_number<=0;held_summary_status<=0;peak_history_valid<=0;
 end else begin
 ack_meta<=acknowledge;ack_sync<=ack_meta;
 if(waiting && ack_sync==request) begin waiting<=0;write_bank<=~write_bank;end
 if(state==PUBLISH && !waiting && !copying) begin copying<=1;copy_index<=0;end
 if(copying) begin
 if(copy_index<64) begin
 pending_levels[{copy_index[5:0],3'b000}+:8]<=band_work[copy_index[5:0]];
 pending_peaks[{copy_index[5:0],3'b000}+:8]<=
 next_peak;
 end
 if(copy_index==511) begin
 // Publish one coherent frame; the CDC bridge must not capture a partial band scan.
 levels<=pending_levels;peaks<=pending_peaks;
 held_summary_status<={overrun,clipped,frame_number+16'd1,peak_sample,rms_sample};
 peak_history_valid<=1;
 copying<=0;waiting<=1;request<=~request;frame_number<=frame_number+1'b1;
 end else copy_index<=copy_index+1'b1;
 end
 end end
 reg read_bank,req_meta,req_sync;
 always @(posedge pixel_clk)
 summary_data<=trace_ready ? summary_memory[{read_bank,summary_address}] : 16'd0;
 always @(posedge pixel_clk) trace_level<=trace_memory[{read_bank,trace_address}];
 always @(posedge pixel_clk or negedge pixel_rst_n) begin
 if(!pixel_rst_n) begin read_bank<=0;req_meta<=0;req_sync<=0;acknowledge<=0;trace_ready<=0;summary_status<=0;end
 else begin
 req_meta<=request;req_sync<=req_meta;
 if(pixel_frame_start && req_sync!=acknowledge) begin
 read_bank<=~read_bank;acknowledge<=req_sync;trace_ready<=1;
 summary_status<=held_summary_status;
 end
 end end
endmodule

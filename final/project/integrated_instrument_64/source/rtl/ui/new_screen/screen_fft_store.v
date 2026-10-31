// Passive FFT display storage. No feedback or backpressure to audio/FFT.
module screen_fft_store #(parameter QUALIFY_SCHEME=0)(
 input wire clk,rst_n,frame_begin,bin_valid,frame_done,
 input wire [12:0] bin_index,input wire [7:0] bin_level,
 input wire capture_reference,
 input wire pixel_clk,pixel_rst_n,pixel_frame_start,
 input wire [9:0] graph_address,zoom_address,input wire [6:0] target_voice,
 output reg [7:0] graph_level,graph_reference,zoom_level,zoom_reference,
 output reg [12:0] zoom_frequency_bin,
 output reg ready,reference_ready,
 input wire sample_valid,
 input wire [15:0] scheme,
 output wire scheme_ready,
 input wire digital_saturated,
 output reg display_saturated
);
 (* syn_ramstyle="block_ram" *) reg [7:0] zoom_memory[0:16383];
 (* syn_ramstyle="block_ram" *) reg [7:0] zoom_reference_memory[0:16383];
 reg write_bank,ref_write_bank,request,waiting,accepted,save_reference;
 reg reference_in_frame;
 reg acknowledge,ack_meta,ack_sync;
 reg read_bank,ref_read_bank,req_meta,req_sync;
 // Sideband only: FFT/audio samples and all numerical transforms are untouched.
 // Invalidate on pending/applied/active/settled changes, including A->B->A.
 reg [15:0] previous_scheme;
 reg [14:0] scheme_samples;
 reg [31:0] epoch,epoch_gray,frame_epoch,published_epoch;
 reg frame_qualified,published_qualified;
 (* async_reg="true" *) reg [31:0] epoch_meta,epoch_sync;
 reg pixel_qualified;
 reg [31:0] pixel_epoch;
 reg clip_seen,published_clip;
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin clip_seen<=0;published_clip<=0;end
 else begin
 if(sample_valid && digital_saturated) clip_seen<=1;
 if(frame_done && accepted) begin
 published_clip<=clip_seen || (sample_valid && digital_saturated);
 clip_seen<=0;
 end
 end end
 wire scheme_changed=scheme!=previous_scheme;
 wire epoch_exhausted=&epoch;
 wire window_qualified=!QUALIFY_SCHEME ||
     (!scheme_changed && !epoch_exhausted && scheme_samples==16384);
 assign scheme_ready=ready && (!QUALIFY_SCHEME ||
     (pixel_qualified && pixel_epoch==epoch_sync));
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
 previous_scheme<=0;scheme_samples<=0;epoch<=0;epoch_gray<=0;
 frame_epoch<=0;frame_qualified<=0;published_epoch<=0;published_qualified<=0;
 end else begin
 previous_scheme<=scheme;
 if(scheme_changed) begin
 scheme_samples<=0;frame_qualified<=0;
 // Saturation fails closed rather than ever accepting a wrapped stale tag.
 if(!epoch_exhausted) begin epoch<=epoch+1'b1;
 epoch_gray<=((epoch+32'd1)>>1)^(epoch+32'd1);end
 end else if(!scheme[14]) scheme_samples<=0;
 else if(sample_valid && scheme_samples<16384) scheme_samples<=scheme_samples+1'b1;
 if(frame_begin) begin
 frame_epoch<=epoch_gray;frame_qualified<=window_qualified;
 end
 if(frame_done && accepted) begin
 published_epoch<=frame_epoch;
 published_qualified<=frame_qualified && !scheme_changed && !epoch_exhausted;
 end
 end end
 always @(posedge pixel_clk or negedge pixel_rst_n) begin
 if(!pixel_rst_n) begin
 epoch_meta<=0;epoch_sync<=0;pixel_epoch<=0;pixel_qualified<=0;display_saturated<=0;
 end else begin
 epoch_meta<=epoch_gray;epoch_sync<=epoch_meta;
 // Published payload is held until the existing bank handshake acknowledges it.
 if(pixel_frame_start && req_sync!=acknowledge) begin
 pixel_epoch<=published_epoch;pixel_qualified<=published_qualified;
 display_saturated<=published_clip;
 end
 end end
 // Qualification must remain true for the complete FFT window/processing period.
 reg reference_qualified;
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
 write_bank<=1;ref_write_bank<=1;request<=0;waiting<=0;accepted<=0;
 save_reference<=0;reference_in_frame<=0;reference_qualified<=0;
 ack_meta<=0;ack_sync<=0;
 end else begin
 ack_meta<=acknowledge;ack_sync<=ack_meta;
 if(waiting && ack_sync==request) begin
 waiting<=0;write_bank<=~write_bank;
 if(reference_in_frame) ref_write_bank<=~ref_write_bank;
 end
 if(frame_begin) begin
 accepted<=!waiting;
 reference_qualified<=capture_reference && window_qualified;
 save_reference<=capture_reference && window_qualified && !waiting;
 end else if(!capture_reference) reference_qualified<=0;
 if(frame_done && accepted) begin
 reference_in_frame<=save_reference && reference_qualified &&
     (!QUALIFY_SCHEME || (frame_qualified && !scheme_changed && !epoch_exhausted));
 request<=~request;waiting<=1;accepted<=0;
 end
 end
 end
 always @(posedge clk) if(bin_valid && accepted) begin
 zoom_memory[{write_bank,bin_index}]<=bin_level;
 if(save_reference) zoom_reference_memory[{ref_write_bank,bin_index}]<=bin_level;
 end
 always @(posedge pixel_clk or negedge pixel_rst_n) begin
 if(!pixel_rst_n) begin
 read_bank<=0;ref_read_bank<=0;req_meta<=0;req_sync<=0;acknowledge<=0;
 ready<=0;reference_ready<=0;
 end else begin
 req_meta<=request;req_sync<=req_meta;
 if(pixel_frame_start && req_sync!=acknowledge) begin
 read_bank<=~read_bank;ready<=1;
 if(reference_in_frame) begin
 ref_read_bank<=ref_write_bank;reference_ready<=1;
 end
 acknowledge<=req_sync;
 end
 end
 end
 // Four FFT bins cover every 8.38-Hz overview pixel. Taking their maximum
 // preserves narrow tones; zoom reads the selected bin neighborhood directly.
 // Exact radix-32 quotient/remainder factorization; no added cycle.
 function [23:0] overview_high;
 input [4:0] address;
 begin
 case(address)
 5'd0: overview_high=24'd837504;
 5'd1: overview_high=24'd1213152;
 5'd2: overview_high=24'd1587104;
 5'd3: overview_high=24'd1962752;
 5'd4: overview_high=24'd2336704;
 5'd5: overview_high=24'd2712352;
 5'd6: overview_high=24'd3086304;
 5'd7: overview_high=24'd3461952;
 5'd8: overview_high=24'd3835904;
 5'd9: overview_high=24'd4211552;
 5'd10: overview_high=24'd4585504;
 5'd11: overview_high=24'd4961152;
 5'd12: overview_high=24'd5335104;
 5'd13: overview_high=24'd5710752;
 5'd14: overview_high=24'd6084704;
 5'd15: overview_high=24'd6460352;
 5'd16: overview_high=24'd6834304;
 5'd17: overview_high=24'd7209952;
 5'd18: overview_high=24'd7583904;
 5'd19: overview_high=24'd7959552;
 5'd20: overview_high=24'd8333504;
 5'd21: overview_high=24'd8709152;
 5'd22: overview_high=24'd9083104;
 5'd23: overview_high=24'd9458752;
 5'd24: overview_high=24'd9832704;
 5'd25: overview_high=24'd10208352;
 5'd26: overview_high=24'd10582304;
 5'd27: overview_high=24'd10957952;
 5'd28: overview_high=24'd11331904;
 5'd29: overview_high=24'd11707552;
 5'd30: overview_high=24'd12083200;
 5'd31: overview_high=24'd12457152;
 default: overview_high=24'd0;
 endcase
 end
 endfunction
 function [18:0] overview_low;
 input [4:0] address;
 begin
 case(address)
 5'd0: overview_low=19'd0;
 5'd1: overview_low=19'd10255;
 5'd2: overview_low=19'd22206;
 5'd3: overview_low=19'd34157;
 5'd4: overview_low=19'd46108;
 5'd5: overview_low=19'd58059;
 5'd6: overview_low=19'd70010;
 5'd7: overview_low=19'd81961;
 5'd8: overview_low=19'd92216;
 5'd9: overview_low=19'd104167;
 5'd10: overview_low=19'd116118;
 5'd11: overview_low=19'd128069;
 5'd12: overview_low=19'd140020;
 5'd13: overview_low=19'd151971;
 5'd14: overview_low=19'd163922;
 5'd15: overview_low=19'd174177;
 5'd16: overview_low=19'd186128;
 5'd17: overview_low=19'd198079;
 5'd18: overview_low=19'd210030;
 5'd19: overview_low=19'd221981;
 5'd20: overview_low=19'd233932;
 5'd21: overview_low=19'd245883;
 5'd22: overview_low=19'd256138;
 5'd23: overview_low=19'd268089;
 5'd24: overview_low=19'd280040;
 5'd25: overview_low=19'd291991;
 5'd26: overview_low=19'd303942;
 5'd27: overview_low=19'd315893;
 5'd28: overview_low=19'd327844;
 5'd29: overview_low=19'd338099;
 5'd30: overview_low=19'd350050;
 5'd31: overview_low=19'd362001;
 default: overview_low=19'd0;
 endcase
 end
 endfunction
 wire [23:0] overview_h=overview_high(graph_address[9:5]);
 wire [18:0] overview_l=overview_low(graph_address[4:0]);
 wire [12:0] overview_remainder={1'b0,overview_h[11:0]}+{1'b0,overview_l[11:0]};
 wire [12:0] overview_base={1'b0,overview_h[23:12]}+{6'd0,overview_l[18:12]};
 wire [12:0] first_bin=overview_base+(overview_remainder>=13'd2400);
 wire [12:0] last_bin=overview_base+13'd2+(overview_remainder>=13'd337)+(overview_remainder>=13'd2737);
 // Exact offset for every 10-bit zoom address; no latency change.
 function [16:0] zoom_high;
 input [4:0] address;
 begin
 case(address)
 5'd0: zoom_high=17'd0;
 5'd1: zoom_high=17'd2304;
 5'd2: zoom_high=17'd4856;
 5'd3: zoom_high=17'd7408;
 5'd4: zoom_high=17'd9960;
 5'd5: zoom_high=17'd12512;
 5'd6: zoom_high=17'd15064;
 5'd7: zoom_high=17'd17616;
 5'd8: zoom_high=17'd20168;
 5'd9: zoom_high=17'd22720;
 5'd10: zoom_high=17'd25272;
 5'd11: zoom_high=17'd27824;
 5'd12: zoom_high=17'd30376;
 5'd13: zoom_high=17'd32928;
 5'd14: zoom_high=17'd35480;
 5'd15: zoom_high=17'd38032;
 5'd16: zoom_high=17'd40584;
 5'd17: zoom_high=17'd43136;
 5'd18: zoom_high=17'd45688;
 5'd19: zoom_high=17'd48240;
 5'd20: zoom_high=17'd50792;
 5'd21: zoom_high=17'd53344;
 5'd22: zoom_high=17'd55896;
 5'd23: zoom_high=17'd58448;
 5'd24: zoom_high=17'd61000;
 5'd25: zoom_high=17'd63552;
 5'd26: zoom_high=17'd66104;
 5'd27: zoom_high=17'd68656;
 5'd28: zoom_high=17'd71208;
 5'd29: zoom_high=17'd73760;
 5'd30: zoom_high=17'd76312;
 5'd31: zoom_high=17'd78864;
 default: zoom_high=17'd0;
 endcase
 end
 endfunction
 function [11:0] zoom_low;
 input [4:0] address;
 begin
 case(address)
 5'd0: zoom_low=12'd0;
 5'd1: zoom_low=12'd41;
 5'd2: zoom_low=12'd82;
 5'd3: zoom_low=12'd123;
 5'd4: zoom_low=12'd164;
 5'd5: zoom_low=12'd205;
 5'd6: zoom_low=12'd246;
 5'd7: zoom_low=12'd535;
 5'd8: zoom_low=12'd576;
 5'd9: zoom_low=12'd617;
 5'd10: zoom_low=12'd658;
 5'd11: zoom_low=12'd699;
 5'd12: zoom_low=12'd740;
 5'd13: zoom_low=12'd1029;
 5'd14: zoom_low=12'd1070;
 5'd15: zoom_low=12'd1111;
 5'd16: zoom_low=12'd1152;
 5'd17: zoom_low=12'd1193;
 5'd18: zoom_low=12'd1234;
 5'd19: zoom_low=12'd1275;
 5'd20: zoom_low=12'd1564;
 5'd21: zoom_low=12'd1605;
 5'd22: zoom_low=12'd1646;
 5'd23: zoom_low=12'd1687;
 5'd24: zoom_low=12'd1728;
 5'd25: zoom_low=12'd1769;
 5'd26: zoom_low=12'd2058;
 5'd27: zoom_low=12'd2099;
 5'd28: zoom_low=12'd2140;
 5'd29: zoom_low=12'd2181;
 5'd30: zoom_low=12'd2222;
 5'd31: zoom_low=12'd2263;
 default: zoom_low=12'd0;
 endcase
 end
 endfunction
 function [7:0] zoom_offset;
 input [9:0] address;
 reg [16:0] high_part;
 reg [11:0] low_part;
 reg [9:0] remainder;
 begin
 high_part=zoom_high(address[9:5]);low_part=zoom_low(address[4:0]);
 remainder={1'b0,high_part[8:0]}+{1'b0,low_part[8:0]};
 zoom_offset=high_part[16:9]+{5'd0,low_part[11:9]}+(remainder>=10'd264);
 end
 endfunction
 wire [12:0] zoom_base={1'b0,target_voice,5'b0}+13'd184;
 integer zoom_bin,j;
 reg [7:0] max_current,max_reference;
 wire [31:0] overview_current,overview_reference;
 genvar lane;
 generate for(lane=0;lane<4;lane=lane+1) begin : overview_lane
 // Valid overview addresses 0..751 never read bin 4096 or above.
 // Keep zoom's full 8192-bin copy; only trim the overview replicas.
 (* syn_ramstyle="block_ram" *) reg [7:0] current_memory[0:2047];
 (* syn_ramstyle="block_ram" *) reg [7:0] reference_memory[0:2047];
 wire [12:0] lane_bin={first_bin[12:2],2'b00}+lane+
     (lane<first_bin[1:0] ? 13'd4 : 13'd0);
 reg [7:0] current_q,reference_q;
 reg current_valid,reference_valid;
 always @(posedge clk) if(bin_valid && accepted && !bin_index[12] && bin_index[1:0]==lane) begin
 current_memory[{write_bank,bin_index[11:2]}]<=bin_level;
 if(save_reference) reference_memory[{ref_write_bank,bin_index[11:2]}]<=bin_level;
 end
 always @(posedge pixel_clk) begin
 current_q<=current_memory[{read_bank,lane_bin[11:2]}];
 reference_q<=reference_memory[{ref_read_bank,lane_bin[11:2]}];
 current_valid<=ready && graph_address<752 && lane_bin<=last_bin;
 reference_valid<=reference_ready && graph_address<752 && lane_bin<=last_bin;
 end
 assign overview_current[lane*8+:8]=current_valid ? current_q : 8'd0;
 assign overview_reference[lane*8+:8]=reference_valid ? reference_q : 8'd0;
 end endgenerate
 always @* begin
 zoom_bin={19'd0,zoom_base}+{24'd0,zoom_offset(zoom_address)};
 max_current=0;max_reference=0;
 for(j=0;j<4;j=j+1) begin
 if(overview_current[j*8+:8]>max_current) max_current=overview_current[j*8+:8];
 if(overview_reference[j*8+:8]>max_reference) max_reference=overview_reference[j*8+:8];
 end
 end
 always @(posedge pixel_clk) begin
 graph_level<=max_current;
 graph_reference<=max_reference;
 zoom_level<=ready && zoom_address<528 ? zoom_memory[{read_bank,zoom_bin[12:0]}] : 8'd0;
 zoom_frequency_bin<=zoom_bin[12:0];
 zoom_reference<=reference_ready && zoom_address<528 ?
 zoom_reference_memory[{ref_read_bank,zoom_bin[12:0]}] : 8'd0;
 end
endmodule

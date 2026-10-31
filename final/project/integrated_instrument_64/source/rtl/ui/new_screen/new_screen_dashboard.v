// New-screen project dashboard. XY reads simultaneous post-FX DAC L/R.
// Linear/zoom FFT ports connect to screen_fft_store in the project top.
(* syn_dspstyle="logic" *)
module new_screen_dashboard #(parameter VOICE_COUNT=64)(
 input wire clk,rst_n,
 input wire [209:0] status,input wire [37:0] acceptance_status,
 input wire [50:0] features,input wire [49:0] fft_status,
 input wire trace_ready,wave_ready,xy_ready,input wire [3:0] wave_shift,
 input wire [26:0] expression_status,
 output wire [8:0] trace_address,input wire [7:0] trace_level,
 output wire [8:0] wave_address,input wire signed [15:0] wave_min,wave_max,
 output wire [13:0] xy_address,input wire xy_hit,
 output wire [5:0] summary_address,input wire [15:0] summary_data,
 output wire [9:0] graph_address,zoom_address,
 input wire [7:0] graph_level,graph_reference,zoom_level,zoom_reference,
 input wire [12:0] zoom_frequency_bin,
 input wire graph_ready,reference_ready,digital_saturated,
 output wire sc_clk,output reg sc_hs,sc_vs,
 output wire frame_start,output reg de,
 output reg [5:0] r,g,b
);
 reg [10:0] h;
 reg [9:0] v;
 reg [209:0] frame;
 reg [37:0] acceptance;
 reg [50:0] feature_frame;
 reg [49:0] metrics;
 reg [26:0] expression_frame;
 reg [2:0] ready_frame;
 reg [7:0] bands[0:63];
 reg [31:0] descriptor;
 wire [15:0] selected_frequency;
 spectral_frequency_rom frequency_label(.clk(clk),.address(feature_frame[46:41]),.value(selected_frequency));
 reg [5:0] strongest_band;
 reg [7:0] strongest_level;
 wire [15:0] strongest_frequency;
 reg [7:0] zoom_peak_level;
 reg [12:0] zoom_peak_bin;
 spectral_frequency_rom strongest_label(.clk(clk),.address(strongest_band),.value(strongest_frequency));
 wire [2:0] page={frame[149],frame[71:70]};
 wire [6:0] actual={frame[115],frame[78:73]};
 wire [6:0] selection=acceptance[22:16];
 wire [6:0] applied=acceptance[36:30];
 wire [6:0] expected=acceptance[29:23];
 wire stable=acceptance[37];
 wire [31:0] target_voice_wide=selection>=5 ? selection-4 :
     selection==0 ? 1 : (selection-1)*(VOICE_COUNT/4)+1;
 wire [6:0] target_voice=target_voice_wide[6:0];
 wire [31:0] target_hundredths=((32'd257+32'd32*(target_voice-1))*32'd18750+32'd32)/32'd64;
 `include "display_targets.vh"
 wire [31:0] target_format=target_labels(target_voice);
 assign sc_clk=clk;
 assign frame_start=h==0 && v==0;
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin h<=0;v<=0;frame<=0;acceptance<=0;feature_frame<=0;metrics<=0;ready_frame<=0;expression_frame<=0;end
 else begin
 if(h==1055) begin h<=0;v<=v==524 ? 0 : v+1'b1;end else h<=h+1'b1;
 if(frame_start) begin
 frame<=status;acceptance<=acceptance_status;feature_frame<=features;metrics<=fft_status;
 expression_frame<=expression_status;
 ready_frame<={trace_ready,wave_ready,xy_ready};
 end
 end

 // Static label tilemaps refer to shared glyph tiles, not whole-screen images.
 // Dynamic digits are selected below from frame-held real status buses.
 (* syn_romstyle="block_rom" *) reg [7:0] row_map[0:511];
 (* syn_romstyle="block_rom" *) reg [9:0] group_map[0:4095];
 (* syn_romstyle="block_rom" *) reg [17:0] compact_cells[0:8191];
 (* syn_romstyle="block_rom" *) reg [63:0] glyph_tiles[0:2047];
 (* syn_romstyle="block_rom" *) reg [10:0] label_tiles[0:2047];
 initial begin
 $readmemh("source/rtl/ui/new_screen/hardware_rows.hex",row_map);
 $readmemh("source/rtl/ui/new_screen/hardware_groups.hex",group_map);
 $readmemh("source/rtl/ui/new_screen/hardware_compact_cells.hex",compact_cells);
 $readmemh("source/rtl/ui/new_screen/hardware_glyphs.hex",glyph_tiles);
 $readmemh("source/rtl/ui/new_screen/hardware_labels.hex",label_tiles);
 end
 `include "new_screen_font_defs.vh"
 function integer value_for;
 input integer slot;
 begin case(slot)
 0:value_for=frame[31:16];
 1:value_for=actual;
 2:value_for=frame[106:102]+1;
 3:value_for=frame[94:87];
 4:value_for=frame[188:185]*1000+frame[184:181]*100+
             frame[180:177]*10+frame[176:173];
 5:value_for=frame[69:63]*20;
 6:value_for=frame[62:56];
 7:value_for=frame[114:107];
 8:value_for={frame[154:150],frame[123:119]}+frame[116];
 9:value_for=frame[164:155];
 10:value_for=feature_frame[40:31];
 11:value_for=feature_frame[30:21];
 12:value_for=metrics[31:16];
 13:value_for=metrics[15:0];
 14:value_for=selection>=5 ? selection-4 : selection;
 15:value_for=expected;
 16:value_for=target_voice;
 17:value_for=target_format[20:7];
 18:value_for=target_format[6:0];
 19:value_for=metrics[47:32];
 20:value_for=VOICE_COUNT;
 21:value_for=frame[101:95];
 22:value_for=feature_frame[10:9];
 23:value_for=frame[168:167];
 24:value_for=feature_frame[46:41]+1;
 25:value_for=strongest_level!=0 ? strongest_frequency : 0;
 26:value_for=bands[feature_frame[46:41]];
 27:value_for=applied;
 28:value_for=frame[172:169];
 29:value_for=frame[86:79];
 // Bounds are Hz, not the hundredths-Hz unit of target_hundredths.
 // The store spans center-41 through center+40 bins at 48000/16384 Hz.
 30:value_for=page<4 ? (32'd32<<wave_shift) : target_format[20:7]-120+(target_format[6:0]>=62);
 31:value_for=page<4 ? (32'd1024>>wave_shift) : target_format[20:7]+117+(target_format[6:0]>=32);
 32:value_for=page<4 ? expression_frame[25:16] : selected_frequency;
 33:value_for=expression_frame[15:9];
 34:value_for=zoom_peak_level!=0 && graph_ready ?
     (({19'd0,zoom_peak_bin}*32'd375+32'd64)>>7) : 0;
 default:value_for=0;
 endcase end
 endfunction
 function integer places;
 input integer slot;
 begin case(slot)
 0,3,5,6,7,8,9,10,11,21,26,27,29:places=3;
 4,17:places=4;
 30:places=page<4 ? 5 : 4;
 31:places=4;
 12,13,19,25,34:places=5;
 32:places=page<4 ? 4 : 5;
 33:places=3;
 22,23,28:places=1;
 default:places=2;
 endcase end
 endfunction
 function integer label_variant;
 input integer id;
 begin case(id)
 0:label_variant=frame[15:0]<4 ? frame[15:0] : 4;
 1:label_variant=frame[69:63]==0 ? 2 : frame[72] ? 1 : 0;
 2:label_variant=frame[62:56]!=0;
 3:label_variant=frame[165] ? 3 : frame[166] ? 2 : frame[116] ? 1 : 0;
 4:label_variant=frame[94:87]==0 ? 0 : frame[94:87]>32 ? 2 : 1;
 5:label_variant=frame[209] ? 1 : 0;
 6:label_variant=!frame[148] ? 0 : selection!=applied ? 1 : !stable ? 2 : graph_ready ? 4 : 3;
 7:label_variant=metrics[49] ? 2 : (!ready_frame[2] || metrics[47:32]==0) ? 0 : 1;
 8:label_variant=digital_saturated ? 2 : metrics[48];
 9:label_variant=frame[148];
 10:label_variant=ready_frame[1];
 11:label_variant=ready_frame[0];
 12:label_variant=reference_ready;
 13:label_variant=expression_frame[26];
 default:label_variant=0;
 endcase end
 endfunction
 // All displayed values fit signed 18 bits. Fixed 17-bit double-dabble
 // preserves signed decimal digits without five 32-bit divide/modulo paths.
 function integer decimal_digit;
 input integer value,position;
 reg [16:0] magnitude;
 reg [19:0] bcd;
 integer bit_index,nibble;
 begin
 magnitude=value<0 ? -value : value;
 bcd=0;
 for(bit_index=16;bit_index>=0;bit_index=bit_index-1) begin
 for(nibble=0;nibble<5;nibble=nibble+1)
 if(bcd[nibble*4+:4]>=5) bcd[nibble*4+:4]=bcd[nibble*4+:4]+4'd3;
 bcd={bcd[18:0],magnitude[bit_index]};
 end
 case(position)
 4:decimal_digit=bcd[19:16];
 3:decimal_digit=bcd[15:12];
 2:decimal_digit=bcd[11:8];
 1:decimal_digit=bcd[7:4];
 default:decimal_digit=bcd[3:0];
 endcase
 if(value<0) decimal_digit=-decimal_digit;
 end
 endfunction
 reg [19:0] numeric_bcd[0:34];
 reg [34:0] numeric_negative;
 reg numeric_busy;
 reg [5:0] numeric_slot;
 reg [4:0] numeric_step;
 reg [16:0] numeric_magnitude;
 reg [19:0] numeric_work;
 reg signed [17:0] numeric_value;
 reg [19:0] numeric_adjusted;
 integer numeric_nibble,numeric_reset;
 always @* begin
 numeric_adjusted=numeric_work;
 for(numeric_nibble=0;numeric_nibble<5;numeric_nibble=numeric_nibble+1)
 if(numeric_work[numeric_nibble*4+:4]>=5)
 numeric_adjusted[numeric_nibble*4+:4]=numeric_work[numeric_nibble*4+:4]+4'd3;
 end
 // The earliest numeric glyph is row 24. Finish all 30 values on line 2,
 // after the analyzer summary on line 1 and before any numeric glyph is read.
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin
 numeric_busy<=0;numeric_slot<=0;numeric_step<=0;
 numeric_magnitude<=0;numeric_work<=0;numeric_value<=0;numeric_negative<=0;
 for(numeric_reset=0;numeric_reset<35;numeric_reset=numeric_reset+1)
 numeric_bcd[numeric_reset]<=0;
 end else if(v==2 && h==0) begin
 numeric_busy<=1;numeric_slot<=0;numeric_step<=0;
 end else if(numeric_busy) begin
 if(numeric_step==0) begin
 numeric_value<=value_for(numeric_slot);numeric_step<=1;
 end else if(numeric_step==1) begin
 numeric_magnitude<=numeric_value<0 ? -numeric_value : numeric_value;
 numeric_negative[numeric_slot]<=numeric_value<0;
 numeric_work<=0;numeric_step<=2;
 end else if(numeric_step<19) begin
 numeric_work<={numeric_adjusted[18:0],numeric_magnitude[16]};
 numeric_magnitude<={numeric_magnitude[15:0],1'b0};
 numeric_step<=numeric_step+1'b1;
 end else begin
 numeric_bcd[numeric_slot]<=numeric_work;
 numeric_step<=0;
 if(numeric_slot==34) numeric_busy<=0;
 else numeric_slot<=numeric_slot+1'b1;
 end
 end
 reg [3:0] cached_digit;
 wire [5:0] numeric_address=descriptor[29:24];
 wire [19:0] cached_bcd=numeric_bcd[numeric_address];
 always @* begin
 // Font generation encodes the right-to-left BCD index, including page width.
 case(descriptor[12:10])
 4:cached_digit=cached_bcd[19:16];
 3:cached_digit=cached_bcd[15:12];
 2:cached_digit=cached_bcd[11:8];
 1:cached_digit=cached_bcd[7:4];
 default:cached_digit=cached_bcd[3:0];
 endcase
 end
 wire signed [4:0] displayed_digit=numeric_negative[numeric_address] ?
     -$signed({1'b0,cached_digit}) : $signed({1'b0,cached_digit});
 function [10:0] numeric_tile;
 input signed [4:0] number;
 input [3:0] size,row,col;
 reg signed [10:0] digit_wide,row_wide,col_wide;
 begin
 digit_wide=number;row_wide=$signed({1'b0,row});col_wide=$signed({1'b0,col});
 case(size)
 2:numeric_tile=11'd1+digit_wide*11'sd4+row_wide*11'sd2+col_wide;
 3:numeric_tile=11'd41+digit_wide*11'sd9+row_wide*11'sd3+col_wide;
 5:numeric_tile=11'd131+digit_wide*11'sd25+row_wide*11'sd5+col_wide;
 default:numeric_tile=0;
 endcase
 end
 endfunction
 integer tile_id,slot,scale,digit_pos,digit,label_address;
 reg [2:0] decoded_color,text_color;
 reg [7:0] row_id;
 reg [9:0] group_id;
 reg [2:0] group_offset;
 reg [17:0] compact_cell;
 function [31:0] expand_cell;
 input [17:0] token;
 reg [31:0] expanded;
 begin
 expanded=0;
 case(token[17:16])
 2:begin
 expanded[31]=1;
 expanded[29:24]=token[15:10];
 expanded[23:20]=token[9] ? 4'd3 : 4'd2;
 expanded[14:13]=token[8:7];
 expanded[12:10]=token[6:4];
 expanded[5:4]=token[3:2];
 expanded[1:0]=token[1:0];
 end
 1:begin
 expanded[30]=1;
 expanded[27:24]=token[11:8];
 expanded[17:16]=token[7:6];
 expanded[9:8]=token[5:4];
 expanded[3:0]=token[3:0];
 end
 default:begin
 expanded[17:16]=token[12:11];
 expanded[10:0]=token[10:0];
 end
 endcase
 expand_cell=expanded;
 end
 endfunction
 reg [10:0] direct_tile,label_tile;
 reg [6:0] column_d;
 reg label_select;
 reg [2:0] color_d,color_g;
 reg [63:0] prefetched_glyph,active_glyph;
 wire [10:0] look_h=h>=1048 ? h-1048 : h+8;
 wire [9:0] look_v=h>=1048 ? (v==524 ? 10'd0 : v+1'b1) : v;
 wire [2:0] map_page=(page==4 && selection!=0) ? (selection<5 ? 3'd6 : 3'd7) : page;
 wire [8:0] font_row_address=look_v<480 && page<6 ? map_page*9'd60+look_v[9:3] : 9'd0;
 wire [6:0] column=look_h<800 ? look_h[9:3] : 7'd0;
 // Six single-read synchronous ROMs finish within one eight-pixel tile.
 // The last blanking tile prefetches column zero of the following line.
 always @(posedge clk) begin
 row_id<=row_map[font_row_address];column_d<=column;
 group_id<=group_map[{row_id,column_d[6:3]}];group_offset<=column_d[2:0];
 // Preserve the descriptor pipeline clock while removing the indirect ROM.
 compact_cell<=compact_cells[{group_id,group_offset}];
 descriptor<=expand_cell(compact_cell);
 label_tile<=label_tiles[label_address[10:0]];
 direct_tile<=tile_id[10:0];label_select<=descriptor[30] && !descriptor[31];
 color_d<=decoded_color;
 prefetched_glyph<=glyph_tiles[label_select ? label_tile : direct_tile];
 color_g<=color_d;
 end
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin active_glyph<=0;text_color<=0;end
 else if(h[2:0]==7) begin active_glyph<=prefetched_glyph;text_color<=color_g;end
 wire text_hit=h<800 && v<480 && page<6 &&
     active_glyph[63-{v[2:0],h[2:0]}];
 always @* begin
 tile_id=descriptor[10:0];decoded_color=descriptor[18:16];label_address=0;
 slot=0;scale=2;digit_pos=0;digit=0;
 if(descriptor[31]) begin
 slot=descriptor[30:24];
 scale=descriptor[23:20];
 digit_pos=descriptor[19:16];
 decoded_color=descriptor[15:13];
 digit=displayed_digit;
 tile_id=numeric_tile(displayed_digit,descriptor[23:20],descriptor[7:4],descriptor[3:0]);
 end else if(descriptor[30]) begin
 slot=descriptor[29:24];
 decoded_color=descriptor[18:16];
 label_address=label_index(slot,label_variant(slot),descriptor[11:8],descriptor[7:0]);
 end
 end
 // One-cycle addressed interfaces, preloaded for the next active pixel.
 assign trace_address=(h>=23 && h<535) ? h-23 : 0;
 assign wave_address=(h>=23 && h<535) ? h-23 : 0;
 wire [6:0] xy_x=h-11'd595;
 wire [6:0] xy_y=7'd127-(v-10'd184);
 assign xy_address={xy_y,xy_x};
 // Overview RAM plus maximum reduction takes two clocks; zoom takes one.
 assign graph_address=h>=22 && h<774 ? h-22 : 0;
 assign zoom_address=h>=23 && h<551 ? h-23 : 0;
 assign summary_address=h[5:0];
 reg [7:0] band_peaks[0:63];
 reg [5:0] summary_index;
 reg summary_valid;
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin zoom_peak_level<=0;zoom_peak_bin<=0;end
 else if(v==1 && h==0) begin zoom_peak_level<=0;zoom_peak_bin<=0;end
 else if(v==1 && h>=24 && h<552 && graph_ready && zoom_level>zoom_peak_level) begin
 zoom_peak_level<=zoom_level;zoom_peak_bin<=zoom_frequency_bin;
 end
 always @(posedge clk) begin
 summary_index<=summary_address;
 summary_valid<=v==1 && h<64;
 if(!rst_n || (v==1 && h==0)) begin strongest_level<=0;strongest_band<=0;end
 if(summary_valid) begin
 bands[summary_index]<=summary_data[7:0];band_peaks[summary_index]<=summary_data[15:8];
 if(summary_data[7:0]>strongest_level) begin
 strongest_level<=summary_data[7:0];strongest_band<=summary_index;
 end
 end
 end
 (* syn_ramstyle="block_ram" *) reg [7:0] history[0:4095];
 reg [5:0] history_row;
 reg [6:0] history_filled;
 reg [15:0] history_number;
 reg copying;
 integer history_i;
 wire [10:0] history_next_h=h==1055 ? 11'd0 : h+1'b1;
 wire [9:0] history_next_v=h==1055 ? (v==524 ? 10'd0 : v+1'b1) : v;
 wire [9:0] history_delta=history_next_h-11'd24;
 wire [5:0] history_column=history_delta[8:3];
 // A horizontal time trace for the selected frequency band: oldest left,
 // newest right. Each eight-pixel cell is one accepted history update.
 wire [9:0] history_time_x=history_next_h-11'd64;
 wire [5:0] history_next_age=6'd63-history_time_x[8:3];
 wire [5:0] history_read_row=history_row+6'd63-history_next_age;
 reg [7:0] history_pixel;
 always @(posedge clk)
 history_pixel<=history[{history_read_row,feature_frame[46:41]}];
 wire [17:0] history_rgb=history_palette(history_pixel);
 reg [3:0] beat_radius;
 always @* begin
 case(v)
 250,268:beat_radius=4;
 251,267:beat_radius=5;
 252,253,265,266:beat_radius=7;
 254,264:beat_radius=8;
 default:beat_radius=9;
 endcase
 end
 wire [3:0] beat_hit={
     h+beat_radius>=664 && h<=664+beat_radius,
     h+beat_radius>=592 && h<=592+beat_radius,
     h+beat_radius>=520 && h<=520+beat_radius,
     h+beat_radius>=448 && h<=448+beat_radius};
 reg [7:0] peak_pixel;
 reg [7:0] analysis_pixel;
 always @(posedge clk)
 begin
 peak_pixel<=band_peaks[history_column];
 analysis_pixel<=bands[history_column];
 end
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin history_row<=0;history_filled<=0;history_number<=0;copying<=0;end
 else begin
 if(v==2 && h==0 && metrics[47:32]!=history_number) begin
 copying<=1;history_number<=metrics[47:32];
 end
 if(copying && h>=1 && h<=64) history[{history_row,6'd0}+h-1]<=bands[h-1];
 if(copying && h==65) begin
 copying<=0;history_row<=history_row+1'b1;
 if(history_filled<64) history_filled<=history_filled+1'b1;
 end
 end

 reg [5:0] rr,gg,bb;
 // Exact original integer ordinate for every eight-bit FFT level.
 function signed [9:0] overview_ordinate;
 input [7:0] level;
 reg [12:0] high_part;
 reg [8:0] low_part;
 reg [4:0] remainder;
 reg [9:0] quotient;
 begin
 case(level[7:4])
 4'd0: high_part=13'd0;
 4'd1: high_part=13'd375;
 4'd2: high_part=13'd750;
 4'd3: high_part=13'd1126;
 4'd4: high_part=13'd1501;
 4'd5: high_part=13'd1877;
 4'd6: high_part=13'd2252;
 4'd7: high_part=13'd2628;
 4'd8: high_part=13'd3003;
 4'd9: high_part=13'd3379;
 4'd10: high_part=13'd3754;
 4'd11: high_part=13'd4130;
 4'd12: high_part=13'd4505;
 4'd13: high_part=13'd4881;
 4'd14: high_part=13'd5256;
 4'd15: high_part=13'd5632;
 default: high_part=13'd0;
 endcase
 case(level[3:0])
 4'd0: low_part=9'd0;
 4'd1: low_part=9'd23;
 4'd2: low_part=9'd46;
 4'd3: low_part=9'd70;
 4'd4: low_part=9'd93;
 4'd5: low_part=9'd117;
 4'd6: low_part=9'd140;
 4'd7: low_part=9'd164;
 4'd8: low_part=9'd187;
 4'd9: low_part=9'd211;
 4'd10: low_part=9'd234;
 4'd11: low_part=9'd258;
 4'd12: low_part=9'd281;
 4'd13: low_part=9'd305;
 4'd14: low_part=9'd328;
 4'd15: low_part=9'd352;
 default: low_part=9'd0;
 endcase
 remainder={1'b0,high_part[3:0]}+{1'b0,low_part[3:0]};
 quotient=high_part[12:4]+low_part[8:4]+(remainder>=5'd15);
 overview_ordinate=10'd288-quotient;
 end
 endfunction
 function [8:0] zoom_ordinate;
 input [7:0] level;
 reg [14:0] high_part;
 reg [10:0] low_part;
 reg [7:0] remainder;
 reg [8:0] quotient;
 begin
 case(level[7:4])
 4'd0: high_part=15'd0;
 4'd1: high_part=15'd1208;
 4'd2: high_part=15'd2416;
 4'd3: high_part=15'd3632;
 4'd4: high_part=15'd4840;
 4'd5: high_part=15'd6056;
 4'd6: high_part=15'd7264;
 4'd7: high_part=15'd8480;
 4'd8: high_part=15'd9688;
 4'd9: high_part=15'd10904;
 4'd10: high_part=15'd12112;
 4'd11: high_part=15'd13328;
 4'd12: high_part=15'd14536;
 4'd13: high_part=15'd15752;
 4'd14: high_part=15'd16960;
 4'd15: high_part=15'd18176;
 default: high_part=15'd0;
 endcase
 case(level[3:0])
 4'd0: low_part=11'd0;
 4'd1: low_part=11'd71;
 4'd2: low_part=11'd150;
 4'd3: low_part=11'd221;
 4'd4: low_part=11'd300;
 4'd5: low_part=11'd371;
 4'd6: low_part=11'd450;
 4'd7: low_part=11'd529;
 4'd8: low_part=11'd600;
 4'd9: low_part=11'd679;
 4'd10: low_part=11'd750;
 4'd11: low_part=11'd829;
 4'd12: low_part=11'd908;
 4'd13: low_part=11'd979;
 4'd14: low_part=11'd1058;
 4'd15: low_part=11'd1129;
 default: low_part=11'd0;
 endcase
 remainder={1'b0,high_part[6:0]}+{1'b0,low_part[6:0]};
 quotient=high_part[14:7]+low_part[10:7]+(remainder>=8'd120);
 zoom_ordinate=9'd431-quotient;
 end
 endfunction
 // For x=24*level=128*a+b, floor(x/127)=a+(a+b>=127).
 // Here a<=47, so the correction is at most one for all 256 input values.
 function [5:0] volume_steps;
 input [7:0] level;
 reg [12:0] product;
 reg [7:0] folded;
 begin
 product=({5'd0,level}<<4)+({5'd0,level}<<3);
 folded={2'd0,product[12:7]}+{1'd0,product[6:0]};
 volume_steps=product[12:7]+(folded>=8'd127);
 end
 endfunction
 integer k,kx,ky,wave_y,wave_y2;
 reg signed [10:0] trace_y,previous_y,graph_y,zoom_y,reference_y,prior_y;
 integer history_age,history_band,history_value,row_address;
 reg [7:0] last_trace,last_graph,last_reference,last_zoom,last_zoom_reference;
 // Two identical small banks provide neighboring real bins without adding
 // another read port or replica to the full 8192-bin FFT storage.
 (* syn_ramstyle="distributed_ram" *) reg [15:0] zoom_plot_a[0:127];
 (* syn_ramstyle="distributed_ram" *) reg [15:0] zoom_plot_b[0:127];
 // Exact x*41/264 scan conversion. The raster visits every pixel in order;
 // replacing the coordinate ROM avoids a large combinational ROM/mux cone.
 reg [8:0] plot_remainder;
 reg [6:0] plot_offset;
 wire [9:0] plot_sum={1'b0,plot_remainder}+10'd41;
 wire plot_carry=plot_sum>=10'd264;
 wire [8:0] plot_remainder_next=plot_carry ? plot_sum-10'd264 : plot_sum;
 function [7:0] plot_fraction_for;
 input [8:0] remainder;
 reg [3:0] correction;
 begin
 // floor(r*256/264) = r-ceil(r/33), for 0 <= r < 264.
 if(remainder==0) correction=0;
 else if(remainder<=33) correction=1;
 else if(remainder<=66) correction=2;
 else if(remainder<=99) correction=3;
 else if(remainder<=132) correction=4;
 else if(remainder<=165) correction=5;
 else if(remainder<=198) correction=6;
 else if(remainder<=231) correction=7;
 else correction=8;
 plot_fraction_for=remainder-correction;
 end
 endfunction
 reg [15:0] plot_mapping,plot_left,plot_right;
 reg [7:0] plot_fraction;
 wire [12:0] plot_base=13'd216+{target_voice-7'd1,5'b000};
 wire [6:0] plot_index=plot_base[6:0]+plot_mapping[14:8];
 wire [6:0] plot_next_index=plot_mapping[14:8]>=81 ? plot_index : plot_index+7'd1;
 always @(posedge clk) begin
 if(v==1 && h>=24 && h<552 && graph_ready) begin
 zoom_plot_a[zoom_frequency_bin[6:0]]<={zoom_reference,zoom_level};
 zoom_plot_b[zoom_frequency_bin[6:0]]<={zoom_reference,zoom_level};
 end
 // One pixel earlier than the unpipelined implementation: interpolate in
 // its own register stage without shifting the final raster by one pixel.
 if(h>=22 && h<549) begin
 plot_remainder<=plot_remainder_next;
 plot_offset<=plot_offset+plot_carry;
 plot_mapping<={1'b0,(plot_offset+{6'd0,plot_carry}),plot_fraction_for(plot_remainder_next)};
 end else begin
 plot_remainder<=0;plot_offset<=0;plot_mapping<=0;
 end
 plot_left<=zoom_plot_a[plot_index];
 plot_right<=zoom_plot_b[plot_next_index];
 plot_fraction<=plot_mapping[14:8]>=81 ? 8'd0 : plot_mapping[7:0];
 end
 function [7:0] interpolate_bin;
 input [7:0] left_value,right_value,fraction;
 reg signed [8:0] difference;
 reg signed [17:0] product;
 reg signed [18:0] result;
 begin
 difference=$signed({1'b0,right_value})-$signed({1'b0,left_value});
 product=difference*$signed({1'b0,fraction});
 result=$signed({1'b0,left_value,8'd0})+product+19'sd128;
 interpolate_bin=result>>>8;
 end
 endfunction
 reg [7:0] plot_level,plot_reference;
 always @(posedge clk) begin
 plot_level<=interpolate_bin(plot_left[7:0],plot_right[7:0],plot_fraction);
 plot_reference<=interpolate_bin(plot_left[15:8],plot_right[15:8],plot_fraction);
 end
 reg [7:0] last_plot,last_plot_reference,last_history;
 always @(posedge clk) begin
 last_plot<=plot_level;last_plot_reference<=plot_reference;
 last_history<=history_pixel;
 end
 reg [8:0] zoom_phase;
 reg zoom_stem;
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin zoom_phase<=0;zoom_stem<=0;end
 else if(h==23) begin zoom_phase<=0;zoom_stem<=1;end
 else begin
 if(zoom_phase>=9'd223) begin
 zoom_phase<=zoom_phase-9'd223;zoom_stem<=1;
 end else begin
 zoom_phase<=zoom_phase+9'd41;zoom_stem<=0;
 end
 end
 reg [2:0] peak_grade;
 function [6:0] legend_height;
 input [7:0] offset;
 reg [14:0] product;
 begin
 product=({7'd0,offset}<<7)-({7'd0,offset}<<3);
 legend_height=product/15'd207;
 end endfunction
 task ink;
 input [5:0] ir,ig,ib;
 begin rr=ir;gg=ig;bb=ib;end
 endtask
 always @(posedge clk) begin
 last_trace<=trace_level;
 last_graph<=graph_level;last_reference<=graph_reference;
 last_zoom<=zoom_level;last_zoom_reference<=zoom_reference;
 end
 always @* begin
 rr=60;gg=57;bb=52;
 if(page>=4) begin rr=61;gg=62;bb=63;end
 k=0;kx=0;ky=0;wave_y=0;trace_y=0;previous_y=0;graph_y=0;zoom_y=0;
 reference_y=0;prior_y=0;wave_y2=0;
 history_age=0;history_band=0;history_value=0;row_address=0;peak_grade=0;
 if(v==63 && h>=24 && h<776) ink(51,51,50);
 if(page<4) begin
 if((v==112 || v==436) && h>=24 && h<776) ink(51,51,50);
 if(h>=24 && h<776 && v>=345 && v<=410) begin
 k=(h-24)/32;kx=(h-24)%32;
 if(k<24 && kx<27) begin
 ink(56,56,55);
 if(frame[147:124] & (24'd1<<k)) ink(63,53,0);
 if(frame[55:32] & (24'd1<<k)) ink(41,10,13);
 end
 end
 if(v>=333 && v<=341 && h>=24 && h<792) begin
 k=(h-24)/32;kx=(h-24)%32;
 if(k<24 && frame[124+k] && kx>=6+(v-333)/2 && kx<=20-(v-333)/2) ink(63,53,0);
 end
 // Bank-held display scaling, never audio gain. Capture peak determines
 // a common min/max scale with headroom and delayed gain recovery.
 if(h>=24 && h<536 && v>=200 && v<=264) begin
 if(v==200 || v==232 || v==264 || h[6:0]==24) ink(51,51,50);
 wave_y=232-($signed(wave_min)>>>wave_shift);
 wave_y2=232-($signed(wave_max)>>>wave_shift);
 if(ready_frame[1] && v>=wave_y2 && v<=wave_y) ink(41,10,13);
 end
 if(h>=596 && h<724 && v>=184 && v<312) begin
 if(h==660 || v==248) ink(51,51,50);
 if(ready_frame[0] && xy_hit) ink(41,10,13);
 end
 if(page==3 && v>=128 && v<=143 && h>=432 && h<720 && |beat_hit) begin
 if(beat_hit[frame[118:117]]) ink(41,10,13);else ink(54,51,47);
 end
 end
 if(page==5) begin
 // Use the existing 512-column FFT trace, not expanded 64-band stems.
 if(h>=24 && h<536 && v>=104 && v<=255) begin
 ink(63,63,63);
 if(v==105 || v==180 || v==255 || h[6:0]==24) ink(55,57,59);
 trace_y=255-trace_level-(trace_level>>2);
 previous_y=255-last_trace-(last_trace>>2);
 if(ready_frame[2] && (v==trace_y || v+1==trace_y ||
     (v>=trace_y && v<=previous_y) || (v>=previous_y && v<=trace_y))) ink(0,34,32);
 if(ready_frame[2] && h[2:0]>=2 && h[2:0]<=6 && peak_pixel>0 &&
     v==255-peak_pixel-(peak_pixel>>2)) ink(41,10,13);
 if(h==28+{feature_frame[46:41],3'b000} && v[2:0]<3) ink(41,10,13);
 end
 if(h>=64 && h<=568 && v>=336 && v<=431) begin
 ink(63,63,63);
 if(v==336 || v==384 || v==431 || h[5:0]==0) ink(55,57,59);
 history_age=63-((h-64)>>3);
 history_value=history_pixel;
 trace_y=431-((history_pixel*3)>>2);
 previous_y=431-((last_history*3)>>2);
 if(history_age<history_filled &&
     (v==trace_y || v+1==trace_y || (h!=64 && history_age+1<history_filled &&
      ((v>=trace_y && v<=previous_y) || (v>=previous_y && v<=trace_y)))))
 ink(0,34,32);
 // Only acquired history is shown. No fabricated pre-start trace.
 if(h==568 && history_filled!=0 && v+2>=trace_y && v<=trace_y+2) ink(41,10,13);
 end
 end
 if(page==4) begin
 if(h>=24 && h<776 && v>=112 && v<=288) begin
 ink(63,63,63);
 if(v==112 || v==170 || v==228 || v==288 || h[6:0]==24) ink(55,57,59);
 graph_y=$signed(overview_ordinate(graph_level));
 reference_y=$signed(overview_ordinate(reference_ready ? graph_reference : 8'd0));
 prior_y=$signed(overview_ordinate(reference_ready ? last_reference : 8'd0));
 if(reference_ready && h[2:0]<4 &&
     (v==reference_y || (v>=reference_y && v<=prior_y) ||
      (v>=prior_y && v<=reference_y))) ink(41,10,13);
 prior_y=$signed(overview_ordinate(last_graph));
 if(graph_ready && (v==graph_y || v+1==graph_y || (v>=graph_y && v<=prior_y) ||
     (v>=prior_y && v<=graph_y))) ink(0,34,32);
 if(h==target_format[31:21] && v[2:0]<3) ink(41,10,13);
 if(h>=target_format[31:21]-14 && h<=target_format[31:21]+14 &&
     (v==113 || v==119 ||
      h==target_format[31:21]-14 || h==target_format[31:21]+14) &&
     v<=119) ink(41,10,13);
 end
 if(h>=24 && h<552 && v>=360 && v<=431) begin
 ink(63,63,63);
 if(v==360 || v==396 || v==431 || h[6:0]==24) ink(55,57,59);
 zoom_y=zoom_ordinate(plot_level);
 reference_y=zoom_ordinate(reference_ready ? plot_reference : 8'd0);
 prior_y=zoom_ordinate(reference_ready ? last_plot_reference : 8'd0);
 if(reference_ready && h[2:0]<4 &&
     (v==reference_y || (v>=reference_y && v<=prior_y) ||
      (v>=prior_y && v<=reference_y))) ink(41,10,13);
 prior_y=zoom_ordinate(last_plot);
 // Linear raster interpolation is bounded by the two measured neighboring
 // bins; it adds no noise, peaks, smoothing or frequency resolution.
 if(graph_ready && (v==zoom_y || v+1==zoom_y || (v>=zoom_y && v<=prior_y) ||
     (v>=prior_y && v<=zoom_y))) ink(0,34,32);
 if(h==288 && v[2:0]<3) ink(41,10,13);
 end
 end
 if(text_hit) begin
 case(text_color)
 1:ink(24,24,24);
 2:ink(41,10,13);
 3:ink(8,31,30);
 default:ink(9,9,9);
 endcase
 if(page<4 && v>=345 && v<=410 && h>=24 && h<776 &&
 frame[32+(h-24)/32]) ink(63,63,63);
 end
 end
 // Match the delivery dashboard's two-stage RGB/DE output latency.
 reg [5:0] rp,gp,bp;
 reg dp,hp,vp;
 always @(posedge clk or negedge rst_n)
 if(!rst_n) begin rp<=0;gp<=0;bp<=0;dp<=0;hp<=1;vp<=1;end
 else begin rp<=rr;gp<=gg;bp<=bb;dp<=h<800 && v<480;hp<=!(h>=840 && h<968);vp<=!(v>=493 && v<495);end
 always @(negedge clk or negedge rst_n)
 if(!rst_n) begin r<=0;g<=0;b<=0;de<=0;sc_hs<=1;sc_vs<=1;end
 else begin r<=rp;g<=gp;b<=bp;de<=dp;sc_hs<=hp;sc_vs<=vp;end
endmodule

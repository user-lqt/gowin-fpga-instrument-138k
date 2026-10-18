module instrument_dashboard(input wire pixel_clk,rst_n,input wire [209:0] status,
 input wire [127:0] spectrum,
 input wire [48:0] features,
 output wire [13:0] xy_address,input wire xy_hit,xy_ready,
 output wire [8:0] wave_address,input wire signed [15:0] wave_min,wave_max,input wire wave_ready,
 output wire sc_clk,output reg sc_hs,sc_vs,sc_de,output wire frame_start,
 output reg [5:0] r_out,g_out,b_out);
 reg [10:0] h;reg [9:0] v;
 wire active=h<800 && v<480;
 reg [209:0] frame;
 reg [127:0] levels;
 reg [48:0] feature_frame;
 wire [3:0] gain_shift=feature_frame[48:45],inspect_band=feature_frame[44:41];
 wire [2:0] timing_grade=feature_frame[2:0];
 wire count_in=feature_frame[4],rhythm_enabled=feature_frame[5],recording=feature_frame[6];
 wire [1:0] local_song=feature_frame[10:9];
 wire [9:0] records=feature_frame[20:11],misses=feature_frame[30:21],corrects=feature_frame[40:31];
 wire [15:0] volume=frame[31:16],instrument=frame[15:0];
 wire [23:0] keys=frame[55:32],guides=frame[147:124];
 wire [6:0] fx=frame[62:56],glide=frame[69:63];
 wire [2:0] menu={frame[149],frame[71:70]};
 wire analysis_page=menu==5;
 wire test_page=menu==4;
 wire enabled=frame[72],running=frame[116];
 wire [1:0] song=frame[168:167];
 wire complete=frame[166],unavailable=frame[165];
 wire [9:0] total=frame[164:155];
 wire [5:0] voices=frame[78:73];
 wire [7:0] errors=frame[86:79],velocity=frame[94:87],tempo=frame[114:107];
 wire [6:0] note=frame[101:95];wire [4:0] key=frame[106:102];
 wire [9:0] position={frame[154:150],frame[123:119]};
 wire [1:0] beat=frame[118:117];
 wire [9:0] glide_ms=glide*10'd20;
 assign frame_start=h==0 && v==0;
 assign sc_clk=pixel_clk;
 // One-cycle synchronous read, preload the next horizontal pixel.
 wire [10:0] wave_offset=h-11'd15;
 assign wave_address=h>=11'd15 && h<11'd527 ? wave_offset[8:0] : 9'd0;
 reg [4:0] key_index;reg [5:0] key_x;
 reg [3:0] analysis_bar;
 reg [4:0] analysis_x;
 always @(posedge pixel_clk or negedge rst_n) begin
 if(!rst_n) begin h<=0;v<=0;frame<=0;levels<=0;feature_frame<=0;key_index<=0;key_x<=0;analysis_bar<=0;analysis_x<=0;end
 else begin
 if(frame_start) begin frame<=status;levels<=spectrum;feature_frame<=features;end
 if(h==11'd1055) begin h<=0;v<=v==10'd524 ? 10'd0 : v+10'd1;end else h<=h+11'd1;
 if(h<15 || h>=783) begin key_index<=0;key_x<=0;end
 else if(key_x==31) begin key_index<=key_index+1'b1;key_x<=0;end
 else key_x<=key_x+1'b1;
 // Track the next pixel's 24-pixel bar cell without combinational /24 or %24.
 if(h<=11'd15 || h>=11'd399) begin analysis_bar<=0;analysis_x<=0;end
 else if(analysis_x==5'd23) begin analysis_x<=0;analysis_bar<=analysis_bar+4'd1;end
 else analysis_x<=analysis_x+5'd1;
 end end
 function [11:0] decimal3;
 input [9:0] n;
 integer bit_index,d;
 reg [11:0] bcd;
 begin
 bcd=0;
 for(bit_index=9;bit_index>=0;bit_index=bit_index-1) begin
 for(d=0;d<3;d=d+1)
 if(bcd[d*4+:4]>=4'd5) bcd[d*4+:4]=bcd[d*4+:4]+4'd3;
 bcd={bcd[10:0],n[bit_index]};
 end
 decimal3=bcd;
 end endfunction
 reg [11:0] b_volume,b_voices,b_key,b_note,b_velocity,b_fx,b_song;
 reg [11:0] b_position,b_total,b_local_song,b_tempo,b_records,b_band,b_level;
 wire [10:0] display_position={1'b0,position}+{10'd0,running};
 reg [3:0] decimal_cursor,decimal_step;
 reg [9:0] decimal_input,decimal_shift;
 reg [11:0] decimal_work;
 function [11:0] adjust_decimal;
 input [11:0] value;integer d;
 begin
 adjust_decimal=value;
 for(d=0;d<3;d=d+1)
 if(value[d*4+:4]>=5) adjust_decimal[d*4+:4]=value[d*4+:4]+4'd3;
 end endfunction
 wire [11:0] decimal_adjusted=adjust_decimal(decimal_work);
 wire [11:0] decimal_next={decimal_adjusted[10:0],decimal_shift[9]};
 // Status is frame-held. One 154-clock scan replaces fourteen parallel
 // combinational binary-to-BCD networks without touching pixel coordinates.
 always @* begin
 case(decimal_cursor)
 // volume is the UI's 0..127 value, not a 16-bit audio gain.
 0:decimal_input=volume[9:0];
 1:decimal_input={4'd0,voices};
 2:decimal_input={5'd0,key}+10'd1;
 3:decimal_input={3'd0,note};
 4:decimal_input={2'd0,velocity};
 5:decimal_input={3'd0,fx};
 6:decimal_input={8'd0,song};
 7:decimal_input=display_position[9:0];
 8:decimal_input=total;
 9:decimal_input={8'd0,local_song};
 10:decimal_input={2'd0,tempo};
 11:decimal_input=records;
 12:decimal_input={6'd0,inspect_band}+10'd1;
 default:decimal_input={2'd0,levels[inspect_band*8+:8]};
 endcase
 end
 always @(posedge pixel_clk or negedge rst_n) begin
 if(!rst_n) begin
 decimal_cursor<=0;decimal_step<=0;decimal_shift<=0;decimal_work<=0;
 b_volume<=0;b_voices<=0;b_key<=0;b_note<=0;b_velocity<=0;b_fx<=0;b_song<=0;
 b_position<=0;b_total<=0;b_local_song<=0;b_tempo<=0;b_records<=0;b_band<=0;b_level<=0;
 end else if(decimal_step==0) begin
 decimal_shift<=decimal_input;decimal_work<=0;decimal_step<=1;
 end else begin
 decimal_shift<={decimal_shift[8:0],1'b0};decimal_work<=decimal_next;
 if(decimal_step==10) begin
 decimal_step<=0;decimal_cursor<=decimal_cursor==4'd13 ? 4'd0 : decimal_cursor+4'd1;
 case(decimal_cursor)
 0:b_volume<=decimal_next;1:b_voices<=decimal_next;2:b_key<=decimal_next;
 3:b_note<=decimal_next;4:b_velocity<=decimal_next;5:b_fx<=decimal_next;
 6:b_song<=decimal_next;7:b_position<=decimal_next;8:b_total<=decimal_next;
 9:b_local_song<=decimal_next;10:b_tempo<=decimal_next;11:b_records<=decimal_next;
 12:b_band<=decimal_next;13:b_level<=decimal_next;
 endcase
 end else decimal_step<=decimal_step+1'b1;
 end end
 function [7:0] digit;
 input [11:0] n;input [1:0] place;
 begin case(place)
 2:digit=8'd48+{4'd0,n[11:8]};
 1:digit=8'd48+{4'd0,n[7:4]};
 default:digit=8'd48+{4'd0,n[3:0]};
 endcase end endfunction
 function [19:0] frequency_bcd;
 input [3:0] index;
 begin case(index)
 0:frequency_bcd=20'h00094;1:frequency_bcd=20'h00188;2:frequency_bcd=20'h00281;3:frequency_bcd=20'h00375;
 4:frequency_bcd=20'h00563;5:frequency_bcd=20'h00750;6:frequency_bcd=20'h01031;7:frequency_bcd=20'h01406;
 8:frequency_bcd=20'h01969;9:frequency_bcd=20'h02719;10:frequency_bcd=20'h03750;11:frequency_bcd=20'h05156;
 12:frequency_bcd=20'h07125;13:frequency_bcd=20'h09844;14:frequency_bcd=20'h13594;15:frequency_bcd=20'h18750;
 endcase end endfunction
 function [399:0] text_line;
 input [4:0] row;
 reg [399:0] line;
 begin
 line=0;
 case(row)
0:line=" FPGA INSTRUMENT   PIANO   VOL 000   POLY 00/32   ";
2:line=" WAVEFORM / 21 MS                  PERFORMANCE    ";
4:line="                                  KEY 00          ";
6:line="                                  NOTE 000        ";
8:line="                                  VELOCITY 000    ";
10:line="                                  STRIKE SOFT     ";
12:line="                                  GLIDE OFF       ";
14:line=" DFT / 16 BINS         MONO XY     FX 000/127    ";
16:line="                                  PAGE GLIDE      ";
18:line="                                  SONG 0 WAIT     ";
20:line="                                  STEP 000/000    ";
23:line=" 94HZ   750HZ    18K                             ";
24:line=" SONG: PHONE SELECT / KNOB PICK / HOLD START      ";
25:line={" AB ----.-MS K-- V---",{29{8'h20}}};
 default:line=0;
 endcase
 if(row==24) begin
 if(menu!=2) line=" SONG: ENTER SONG PAGE TO SELECT MUSIC            ";
 else if(unavailable) line=" SONG: SCORE NOT LOADED                           ";
 else if(complete) line=" SONG: COMPLETE / SEND NEXT SELECTION             ";
 else if(running && song==1) line=" SONG: JASMINE / FOLLOW THE BLUE KEY              ";
 else if(running && song==2) line=" SONG: TWINKLE STAR / FOLLOW THE BLUE KEY         ";
 end
 if(row==12) line=recording ? "                                  REC ON  000     " : "                                  REC OFF 000     ";
 if(row==18 && !running && !complete) line="                                  PICK 0 HOLD     ";
 if(row==22) line="                                  BPM 000         ";
 if(row==23 && rhythm_enabled) line="                                  RHYTHM ON       ";
 if(row==24 && rhythm_enabled && running) begin
 if(count_in) line=" GET READY / FOUR BEATS                           ";
 else case(timing_grade)
 1:line=" RHYTHM: EARLY / WAIT FOR THE FIRST NOTE          ";
 2:line=" RHYTHM: GOOD / FOLLOW THE FLASH                  ";
 3:line=" RHYTHM: LATE / PLAY CLOSER TO THE FLASH          ";
 4:line=" RHYTHM: MISS / CONTINUE WITH NEXT NOTE           ";
 default:line=" RHYTHM: FOLLOW THE FLASH                         ";
 endcase end
 if(analysis_page) begin
 case(row)
 2:line=" DFT / SELECT WITH EC11           XY / MONO DELAY";
 4:line="                                                  ";
 6:line="                                                  ";
 8:line="                                                  ";
 10:line="                                                  ";
 12:line="                                                  ";
 14:line="                                                  ";
 16:line="                                                  ";
 18:line="                                                  ";
 20:line=" BIN 00  FREQ 00000 HZ  LEVEL 000                 ";
 22:line=" 94HZ          LOG FREQUENCY            18750HZ   ";
 23:line=" MONO DELAY 0.5MS / RELATIVE DFT / NOT FFT        ";
 endcase end
 if(test_page) begin
 case(row)
 2:line=" MIX WAVE / AUTO SCALE             32 VOICE TEST ";
 4:line="                                  ACTIVE 00/32   ";
 6:line="                                  NOTES 48-79    ";
 8:line="                                  HOLD B: TOGGLE ";
 10:line="                                  TEST STOPPED   ";
 12:line="                                  MIX OUTPUT     ";
 14:line=" MIX SPECTRUM / DFT     MONO XY                   ";
 16:line="                                  16 DFT BINS    ";
 18:line="                                  RELATIVE LEVEL ";
 20:line="                                  NOT CALIBRATED ";
 22:line="                                  XY DELAY 0.5MS ";
 23:line=" 94HZ   750HZ    18K                              ";
 24:line=" ACTIVE VOICE COUNT / 32 SLOTS / NOT FFT         ";
 25:line=" SHORT B NEXT PAGE / HOLD B START OR STOP        ";
 endcase
 if(row==10 && frame[148]) line=voices==32 ?
     "                                  32 ACTIVE      " :
     "                                  TEST RUNNING   ";
 end
 text_line=line;
 end endfunction
 function [7:0] character;
 input [4:0] row;input [5:0] col;
 input [399:0] line;
 reg [19:0] selected_frequency;
 begin
 selected_frequency=frequency_bcd(inspect_band);
 character=col<50 ? line[399-col*8-:8] : 0;
 if(row==0 && col>=31 && col<=33) character=digit(b_volume,33-col);
 if(row==0 && col>=42 && col<=43) character=digit(b_voices,43-col);
 if(row==4 && col>=38 && col<=39) character=digit(b_key,39-col);
 if(row==6 && col>=39 && col<=41) character=digit(b_note,41-col);
 if(row==8 && col>=43 && col<=45) character=digit(b_velocity,45-col);
 if(row==14 && col>=39 && col<=41) character=digit(b_fx,41-col);
 if(row==18 && col>=39 && col<=39) character=digit(b_song,39-col);
 if(row==20 && col>=39 && col<=41) character=digit(b_position,41-col);
 if(row==20 && col>=43 && col<=45) character=digit(b_total,45-col);
 if(row==0 && instrument==1 && col>=19 && col<=24) begin
 case(col) 19:character="G";20:character="U";21:character="I";22:character="T";23:character="A";24:character="R";endcase end
 if(row==0 && instrument==2 && col>=19 && col<=23) begin
 case(col) 19:character="B";20:character="E";21,22:character="L";23:character=" ";endcase end
 if(row==10 && col>=41 && col<=44) begin
 if(velocity==0) case(col) 41:character="N";42:character="O";43:character="N";44:character="E";endcase
 else if(velocity>32) case(col) 41:character="H";42:character="A";43:character="R";44:character="D";endcase
 end
 if(row==16 && col>=39 && col<=43) begin
 case(menu)
 0:case(col) 39:character="G";40:character="L";41:character="I";42:character="D";43:character="E";endcase
 1:case(col) 39:character="F";40:character="X";default:character=" ";endcase
 2:case(col) 39:character="S";40:character="O";41:character="N";42:character="G";default:character=" ";endcase
 3:case(col) 39:character="T";40:character="E";41:character="M";42:character="P";43:character="O";endcase
 4:case(col) 39:character="T";40:character="E";41:character="S";42:character="T";default:character=" ";endcase
 endcase end
 if(row==18 && col>=41 && col<=44) begin
 if(unavailable) case(col) 41:character="N";42:character="O";43:character="N";44:character="E";endcase
 else if(complete) case(col) 41:character="D";42:character="O";43:character="N";44:character="E";endcase
 else if(running) case(col) 41:character="P";42:character="L";43:character="A";44:character="Y";endcase
 end
 if(row==18 && !running && !complete && col==39) character=digit(b_local_song,0);
 if(row==22 && col>=38 && col<=40) character=digit(b_tempo,40-col);
 if(row==12 && col>=42 && col<=44) character=digit(b_records,44-col);
 if(row==25 && frame[209]) begin
 case(col)
 4:character=8'd48+{4'd0,frame[188:185]};
 5:character=8'd48+{4'd0,frame[184:181]};
 6:character=8'd48+{4'd0,frame[180:177]};
 7:character=8'd48+{4'd0,frame[176:173]};
 9:character=8'd48+{4'd0,frame[172:169]};
 14:character=8'd48+{4'd0,frame[208:205]};
 15:character=8'd48+{4'd0,frame[204:201]};
 18:character=8'd48+{4'd0,frame[200:197]};
 19:character=8'd48+{4'd0,frame[196:193]};
 20:character=8'd48+{4'd0,frame[192:189]};
 endcase end
 if(analysis_page) begin
 if(row!=0) character=col<50 ? line[399-col*8-:8] : 0;
 if(row==20) begin
 if(col==5 || col==6) character=digit(b_band,6-col);
 if(col>=14 && col<=18) case(col)
 14:character=8'd48+{4'd0,selected_frequency[19:16]};
 15:character=8'd48+{4'd0,selected_frequency[15:12]};
 16:character=8'd48+{4'd0,selected_frequency[11:8]};
 17:character=8'd48+{4'd0,selected_frequency[7:4]};
 18:character=8'd48+{4'd0,selected_frequency[3:0]};
 endcase
 if(col>=30 && col<=32) character=digit(b_level,32-col);
 end end
 if(test_page && row!=0) begin
 character=col<50 ? line[399-col*8-:8] : 0;
 if(row==4 && col>=42 && col<=43) character=digit(b_voices,43-col);
 end
 end endfunction
 function [34:0] glyph;
 input [7:0] c;
 begin case(c)
48:glyph={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
49:glyph={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
50:glyph={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
51:glyph={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
52:glyph={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
53:glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
54:glyph={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
55:glyph={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
56:glyph={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
57:glyph={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
65:glyph={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
66:glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
67:glyph={5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
68:glyph={5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
69:glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
70:glyph={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
71:glyph={5'b01110,5'b10001,5'b10000,5'b10111,5'b10001,5'b10001,5'b01110};
72:glyph={5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
73:glyph={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111};
74:glyph={5'b00111,5'b00010,5'b00010,5'b00010,5'b10010,5'b10010,5'b01100};
75:glyph={5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001};
76:glyph={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
77:glyph={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
78:glyph={5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001};
79:glyph={5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
80:glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
81:glyph={5'b01110,5'b10001,5'b10001,5'b10001,5'b10101,5'b10010,5'b01101};
82:glyph={5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
83:glyph={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
84:glyph={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
85:glyph={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
86:glyph={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
87:glyph={5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
88:glyph={5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001};
89:glyph={5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100};
90:glyph={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b11111};
47:glyph={5'b00001,5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b10000};
46:glyph={5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b00110,5'b00110};
45:glyph={5'b00000,5'b00000,5'b00000,5'b11111,5'b00000,5'b00000,5'b00000};
 default:glyph=0;
 endcase end endfunction
 // Decode the next pixel's character one clock early, separating numeric/text
 // selection from glyph lookup and RGB priority logic without shifting text.
 wire [10:0] next_h=h==11'd1055 ? 11'd0 : h+11'd1;
 wire [9:0] next_v=h==11'd1055 ? (v==10'd524 ? 10'd0 : v+10'd1) : v;
 // Prepare the line two pixels ahead, so row decoding does not feed the
 // 50-character selection mux in the same cycle.
 wire [9:0] line_v=h>=11'd1054 ? (v==10'd524 ? 10'd0 : v+10'd1) : v;
 reg [399:0] cached_line;
 reg [7:0] char_code;
 always @(posedge pixel_clk or negedge rst_n)
 if(!rst_n) begin char_code<=8'h20;cached_line<=0;end
 else begin
 cached_line<=text_line(line_v[8:4]);
 char_code<=character(next_v[8:4],next_h[9:4],cached_line);
 end
 wire [34:0] bitmap=glyph(char_code);
 wire text_hit=h[3:1]<5 && v[3:1]<7 && bitmap[34-v[3:1]*5-h[3:1]];
 // Upper panel: 512-pixel oscilloscope; lower panels: spectrum and XY.
 function [7:0] waveform_y;
 input signed [15:0] value;
 reg signed [15:0] shifted;
 begin
 shifted=value>>>gain_shift;
 // Clip before subtraction: visible coordinates fit eight bits. This avoids
 // a wide subtract feeding two wide comparators on the RAM-to-RGB path.
 if(shifted>16'sd64) waveform_y=8'd80;
 else if(shifted< -16'sd63) waveform_y=8'd207;
 else waveform_y=8'd144-shifted[7:0];
 end endfunction
 wire [7:0] high_y=waveform_y(wave_max),low_y=waveform_y(wave_min);
 wire [10:0] xy_x_wide=analysis_page ? ((h-11'd511)>>1) :
     (h>=11'd399 && h<11'd527 ? h-11'd399 : 11'd0);
 wire [9:0] xy_y_wide=analysis_page ? ((10'd319-v)>>1) :
     (v>=10'd256 && v<10'd384 ? 10'd383-v : 10'd0);
 wire [6:0] xy_x=xy_x_wide[6:0];
 wire [6:0] xy_y=xy_y_wide[6:0];
 assign xy_address={xy_y,xy_x};
 wire [10:0] bar_offset=h-11'd16;
 wire [3:0] bar_index=analysis_page ? analysis_bar : bar_offset[7:4];
 wire [7:0] bar_level=levels[bar_index*8+:8];
 reg [5:0] r,g,b,rp,gp,bp;reg hp,vp,dp;
 always @* begin
 r=63;g=63;b=63;
 // Header and three framed cards.
 if(v<24) begin r=63;g=63;b=63;end
 if(!analysis_page && h>=8 && h<536 && v>=32 && v<216) begin r=63;g=63;b=63;end
 if(!analysis_page && h>=8 && h<536 && v>=224 && v<384) begin r=63;g=63;b=63;end
 if(!analysis_page && h>=544 && h<792 && v>=32 && v<384) begin r=63;g=63;b=63;end
 if(!analysis_page && ((h==8 || h==535) && v>=32 && v<384 ||
    (h==544 || h==791) && v>=32 && v<384 ||
    (v==32 || v==215 || v==224 || v==383) && h>=8 && h<536)) begin r=32;g=34;b=38;end
 if(!analysis_page && h>=16 && h<528 && v>=80 && v<208) begin
 if(v==144 || h[6:0]==16) begin r=35;g=37;b=40;end
 if(wave_ready && v[7:0]>=high_y && v[7:0]<=low_y) begin r=6;g=29;b=60;end
 end
 // 16 selected frequency bins. Gaps between bars, logarithmic magnitude.
 if(!analysis_page && h>=16 && h<272 && v>=248 && v<360) begin
 if(v==359 || v==311 || v==279) begin r=35;g=37;b=40;end
 if(h[3:0]<12 && bar_level!=0 && v>=360-(bar_level>112 ? 112 : bar_level)) begin
 r=v<300 ? 6 : 4;g=v<300 ? 34 : 24;b=60;
 end end
 // XY bitmap: x=current mono output; y=24-sample delayed output.
 if(!analysis_page && h>=400 && h<528 && v>=256 && v<384) begin
 if(h==464 || v==320) begin r=35;g=37;b=40;end
 if(xy_ready && xy_hit) begin r=25;g=15;b=50;end
 end
 // Meters on the parameter card.
 if(!analysis_page && !test_page && v>=148 && v<152 && h>=552 && h<776) begin
 r=35;g=37;b=40;
 if(h<552+velocity) begin r=6;g=38;b=21;end
 end
 if(v>=392 && v<416) begin r=63;g=63;b=63;end
 // 24 full-width physical key tiles, no text underneath.
 if(!test_page && v>=424 && v<472 && h>=16 && h<784 && key_index<24 && key_x<30) begin
 r=44;g=46;b=50;
 if(guides[key_index]) begin r=6;g=29;b=60;end
 if(keys[key_index]) begin r=6;g=38;b=21;end
 if(v==424 || v==471) begin r=r>>1;g=g>>1;b=b>>1;end
 end
 // 32 count cells, not per-voice amplitudes or inferred spectral peaks.
 if(test_page && v>=424 && v<472 && h>=144 && h<656 && h[3:0]<13) begin
 r=55;g=56;b=58;
 if(((h-11'd144)>>4)<voices) begin r=6;g=29;b=60;end
 end
 if(text_hit && (analysis_page || (!(h<536 && v>=80 && v<208) &&
    !(h>=16 && h<272 && v>=248 && v<360) &&
    !(h>=400 && h<528 && v>=256 && v<384)))) begin r=8;g=10;b=12;end
 if(v<24 && errors!=0 && h>=624 && text_hit) begin r=55;g=12;b=11;end
 if(v>=392 && v<416 && feature_frame[3] && h<8) begin r=15;g=63;b=42;end
 if(analysis_page && v>=64 && v<320) begin
 r=63;g=63;b=63;
 if(h>=16 && h<400) begin
 if(v==319 || v==255 || v==191 || v==127) begin r=35;g=37;b=40;end
 if(analysis_x<5'd19 && v>=320-bar_level*2) begin
 r=bar_index==inspect_band ? 6 : 4;g=29;b=60;
 end end
 if(h>=512 && h<768) begin
 if(h==640 || v==192) begin r=35;g=37;b=40;end
 if(xy_ready && xy_hit) begin r=25;g=15;b=50;end
 end end
 end
 always @(posedge pixel_clk or negedge rst_n) begin
 if(!rst_n) begin rp<=0;gp<=0;bp<=0;hp<=1;vp<=1;dp<=0;end
 else begin rp<=r;gp<=g;bp<=b;hp<=!(h>=840 && h<968);vp<=!(v>=493 && v<495);dp<=active;end end
 always @(negedge pixel_clk or negedge rst_n) begin
 if(!rst_n) begin r_out<=0;g_out<=0;b_out<=0;sc_hs<=1;sc_vs<=1;sc_de<=0;end
 else begin r_out<=rp;g_out<=gp;b_out<=bp;sc_hs<=hp;sc_vs<=vp;sc_de<=dp;end end
 endmodule

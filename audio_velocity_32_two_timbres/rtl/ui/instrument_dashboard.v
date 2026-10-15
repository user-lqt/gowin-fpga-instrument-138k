module instrument_dashboard(input wire pixel_clk,rst_n,input wire [168:0] status,
 input wire [127:0] spectrum,
 input wire [48:0] features,
 output wire [13:0] xy_address,input wire xy_hit,xy_ready,
 output wire [8:0] wave_address,input wire signed [15:0] wave_min,wave_max,input wire wave_ready,
 output wire sc_clk,output reg sc_hs,sc_vs,sc_de,output wire frame_start,
 output reg [5:0] r_out,g_out,b_out);
 reg [10:0] h;reg [9:0] v;
 wire active=h<800 && v<480;
 reg [168:0] frame;
 reg [127:0] levels;
 reg [48:0] feature_frame;
 wire [3:0] gain_shift=feature_frame[48:45],inspect_band=feature_frame[44:41];
 wire analysis_page=menu==5;
 wire [2:0] timing_grade=feature_frame[2:0];
 wire count_in=feature_frame[4],rhythm_enabled=feature_frame[5],recording=feature_frame[6];
 wire [1:0] local_song=feature_frame[10:9];
 wire [9:0] records=feature_frame[20:11],misses=feature_frame[30:21],corrects=feature_frame[40:31];
 wire [15:0] volume=frame[31:16],instrument=frame[15:0];
 wire [23:0] keys=frame[55:32],guides=frame[147:124];
 wire [6:0] fx=frame[62:56],glide=frame[69:63];
 wire [2:0] menu={frame[149],frame[71:70]};
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
 assign wave_address=h>=15 && h<527 ? h-15 : 9'd0;
 reg [4:0] key_index;reg [5:0] key_x;
 always @(posedge pixel_clk or negedge rst_n) begin
 if(!rst_n) begin h<=0;v<=0;frame<=0;levels<=0;feature_frame<=0;key_index<=0;key_x<=0;end
 else begin
 if(frame_start) begin frame<=status;levels<=spectrum;feature_frame<=features;end
 if(h==1055) begin h<=0;v<=v==524 ? 0 : v+1'b1;end else h<=h+1'b1;
 if(h<15 || h>=783) begin key_index<=0;key_x<=0;end
 else if(key_x==31) begin key_index<=key_index+1'b1;key_x<=0;end
 else key_x<=key_x+1'b1;
 end end
 function [7:0] digit;
 input [15:0] n;input [1:0] place;
 begin case(place) 2:digit=48+(n/100)%10;1:digit=48+(n/10)%10;default:digit=48+n%10;endcase end endfunction
 function [15:0] frequency_hz;
 input [3:0] index;
 begin case(index)
 0:frequency_hz=94;1:frequency_hz=188;2:frequency_hz=281;3:frequency_hz=375;
 4:frequency_hz=563;5:frequency_hz=750;6:frequency_hz=1031;7:frequency_hz=1406;
 8:frequency_hz=1969;9:frequency_hz=2719;10:frequency_hz=3750;11:frequency_hz=5156;
 12:frequency_hz=7125;13:frequency_hz=9844;14:frequency_hz=13594;15:frequency_hz=18750;
 endcase end endfunction
 function [7:0] character;
 input [4:0] row;input [5:0] col;
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
14:line=" SPECTRUM / 16 BINS     XY / 0.5MS  FX 000/127    ";
16:line="                                  PAGE GLIDE      ";
18:line="                                  SONG 0 WAIT     ";
20:line="                                  STEP 000/000    ";
23:line=" 94HZ   750HZ    18K               TEST OFF       ";
24:line=" SONG: PHONE SELECT / KNOB PICK / HOLD START      ";
 default:line=0;
 endcase
 if(row==24) begin
 if(menu!=2) line=" SONG: ENTER SONG PAGE TO SELECT MUSIC            ";
 else if(unavailable) line=" SONG: SCORE NOT LOADED                           ";
 else if(complete) line=" SONG: COMPLETE / SEND NEXT SELECTION             ";
 else if(running && song==1) line=" SONG: JASMINE / FOLLOW THE BLUE KEY              ";
 else if(running && song==2) line=" SONG: FINGERPRINT CHORUS / FOLLOW THE BLUE KEY   ";
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
 2:line=" SPECTRUM / SELECT WITH EC11       XY / MONO DELAY";
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
 23:line=" XY: CURRENT AUDIO / DELAY 0.5 MS                 ";
 endcase end
 character=col<50 ? line[399-col*8-:8] : 0;
 if(row==0 && col>=31 && col<=33) character=digit({9'd0,volume[15:9]},33-col);
 if(row==0 && col>=42 && col<=43) character=digit(voices,43-col);
 if(row==4 && col>=38 && col<=39) character=digit(key+1,39-col);
 if(row==6 && col>=39 && col<=41) character=digit(note,41-col);
 if(row==8 && col>=43 && col<=45) character=digit(velocity,45-col);
 if(row==14 && col>=39 && col<=41) character=digit(fx,41-col);
 if(row==18 && col>=39 && col<=39) character=digit({14'd0,song},39-col);
 if(row==20 && col>=39 && col<=41) character=digit(running ? position+1 : position,41-col);
 if(row==20 && col>=43 && col<=45) character=digit(total,45-col);
 if(row==0 && instrument!=0 && col>=19 && col<=23) begin
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
 if(row==23 && frame[148]) begin if(col==41) character="N";if(col==42) character=" ";end
 if(row==18 && !running && !complete && col==39) character=digit({14'd0,local_song},0);
 if(row==22 && col>=38 && col<=40) character=digit(tempo,40-col);
 if(row==12 && col>=42 && col<=44) character=digit(records,44-col);
 if(analysis_page) begin
 if(row!=0) character=col<50 ? line[399-col*8-:8] : 0;
 if(row==20) begin
 if(col==5 || col==6) character=digit(inspect_band+1,6-col);
 if(col>=14 && col<=18) character=48+(frequency_hz(inspect_band)/(col==14 ? 10000 : col==15 ? 1000 : col==16 ? 100 : col==17 ? 10 : 1))%10;
 if(col>=30 && col<=32) character=digit(levels[inspect_band*8+:8],32-col);
 end end
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
 default:glyph=0;
 endcase end endfunction
 wire [7:0] char_code=character(v[8:4],h[9:4]);
 wire [34:0] bitmap=glyph(char_code);
 wire text_hit=h[3:1]<5 && v[3:1]<7 && bitmap[34-v[3:1]*5-h[3:1]];
 // Upper panel: 512-pixel oscilloscope; lower panels: spectrum and XY.
 function signed [17:0] waveform_y;
 input signed [15:0] value;reg signed [17:0] y;
 begin
 y=18'sd144-($signed(value)>>>gain_shift);
 if(y<18'sd80) y=18'sd80;
 else if(y>18'sd207) y=18'sd207;
 waveform_y=y;
 end endfunction
 wire signed [17:0] high_y=waveform_y(wave_max),low_y=waveform_y(wave_min);
 wire [6:0] xy_x=analysis_page ? ((h-511)>>1) : (h>=399 && h<527 ? h-399 : 0);
 wire [6:0] xy_y=analysis_page ? ((319-v)>>1) : (v>=256 && v<384 ? 383-v : 0);
 assign xy_address={xy_y,xy_x};
 wire [3:0] bar_index=analysis_page ? (h-16)/24 : (h-16)>>4;
 wire [7:0] bar_level=levels[bar_index*8+:8];
 reg [5:0] r,g,b,rp,gp,bp;reg hp,vp,dp;
 always @* begin
 r=3;g=5;b=9;
 // Header and three framed cards.
 if(v<24) begin r=7;g=13;b=20;end
 if(!analysis_page && h>=8 && h<536 && v>=32 && v<216) begin r=5;g=9;b=14;end
 if(!analysis_page && h>=8 && h<536 && v>=224 && v<384) begin r=5;g=9;b=14;end
 if(!analysis_page && h>=544 && h<792 && v>=32 && v<384) begin r=5;g=9;b=14;end
 if(!analysis_page && ((h==8 || h==535) && v>=32 && v<384 ||
    (h==544 || h==791) && v>=32 && v<384 ||
    (v==32 || v==215 || v==224 || v==383) && h>=8 && h<536)) begin r=10;g=20;b=29;end
 if(!analysis_page && h>=16 && h<528 && v>=80 && v<208) begin
 if(v==144 || h[6:0]==16) begin r=9;g=17;b=23;end
 if(wave_ready && $signed({1'b0,v})>=high_y && $signed({1'b0,v})<=low_y) begin r=10;g=60;b=44;end
 end
 // 16 selected frequency bins. Gaps between bars, logarithmic magnitude.
 if(!analysis_page && h>=16 && h<272 && v>=248 && v<360) begin
 if(v==359 || v==311 || v==279) begin r=9;g=17;b=23;end
 if(h[3:0]<12 && bar_level!=0 && v>=360-(bar_level>112 ? 112 : bar_level)) begin
 r=v<300 ? 48 : 10;g=v<300 ? 48 : 50;b=58;
 end end
 // XY bitmap: x=current mono output; y=24-sample delayed output.
 if(!analysis_page && h>=400 && h<528 && v>=256 && v<384) begin
 if(h==464 || v==320) begin r=9;g=17;b=23;end
 if(xy_ready && xy_hit) begin r=47;g=27;b=63;end
 end
 // Meters on the parameter card.
 if(!analysis_page && v>=148 && v<152 && h>=552 && h<776) begin
 r=9;g=16;b=22;
 if(h<552+velocity) begin r=10;g=54;b=42;end
 end
 if(v>=392 && v<416) begin r=7;g=13;b=20;end
 // 24 full-width physical key tiles, no text underneath.
 if(v>=424 && v<472 && h>=16 && h<784 && key_index<24 && key_x<30) begin
 r=48;g=51;b=55;
 if(key_index==5) begin r=24;g=27;b=31;end
 if(guides[key_index]) begin r=12;g=34;b=63;end
 if(keys[key_index]) begin r=8;g=58;b=36;end
 if(v==424 || v==471) begin r=r>>1;g=g>>1;b=b>>1;end
 end
 if(text_hit && (analysis_page || (!(h<536 && v>=80 && v<208) &&
    !(h>=16 && h<272 && v>=248 && v<360) &&
    !(h>=400 && h<528 && v>=256 && v<384)))) begin r=55;g=59;b=63;end
 if(v<24 && errors!=0 && h>=624 && text_hit) begin r=63;g=18;b=12;end
 if(v>=392 && v<416 && feature_frame[3] && h<8) begin r=15;g=63;b=42;end
 if(analysis_page && v>=64 && v<320) begin
 r=5;g=9;b=14;
 if(h>=16 && h<400) begin
 if(v==319 || v==255 || v==191 || v==127) begin r=9;g=17;b=23;end
 if((h-16)%24<19 && v>=320-bar_level*2) begin
 r=bar_index==inspect_band ? 50 : 10;g=50;b=58;
 end end
 if(h>=512 && h<768) begin
 if(h==640 || v==192) begin r=9;g=17;b=23;end
 if(xy_ready && xy_hit) begin r=47;g=27;b=63;end
 end end
 end
 always @(posedge pixel_clk or negedge rst_n) begin
 if(!rst_n) begin rp<=0;gp<=0;bp<=0;hp<=1;vp<=1;dp<=0;end
 else begin rp<=r;gp<=g;bp<=b;hp<=!(h>=840 && h<968);vp<=!(v>=493 && v<495);dp<=active;end end
 always @(negedge pixel_clk or negedge rst_n) begin
 if(!rst_n) begin r_out<=0;g_out<=0;b_out<=0;sc_hs<=1;sc_vs<=1;sc_de<=0;end
 else begin r_out<=rp;g_out<=gp;b_out<=bp;sc_hs<=hp;sc_vs<=vp;sc_de<=dp;end end
 endmodule

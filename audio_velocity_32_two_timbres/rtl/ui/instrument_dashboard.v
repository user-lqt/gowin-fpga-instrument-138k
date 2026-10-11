module instrument_dashboard(input wire pixel_clk,rst_n,input wire [149:0] status,
 output wire [8:0] wave_address,input wire signed [15:0] wave_min,wave_max,input wire wave_ready,
 output wire sc_clk,output reg sc_hs,sc_vs,sc_de,output wire frame_start,
 output reg [5:0] r_out,g_out,b_out);
 reg [10:0] h;reg [9:0] v;
 wire active=h<800 && v<480;
 reg [149:0] frame;
 wire [15:0] volume=frame[31:16],instrument=frame[15:0];
 wire [23:0] keys=frame[55:32],guides=frame[147:124];
 wire [6:0] fx=frame[62:56],glide=frame[69:63];
 wire [2:0] menu={frame[149],frame[71:70]};
 wire enabled=frame[72],running=frame[116],song=frame[115];
 wire [5:0] voices=frame[78:73];
 wire [7:0] errors=frame[86:79],velocity=frame[94:87],tempo=frame[114:107];
 wire [6:0] note=frame[101:95];wire [4:0] key=frame[106:102],position=frame[123:119];
 wire [1:0] beat=frame[118:117];
 wire [9:0] glide_ms=glide*10'd20;
 assign frame_start=h==0 && v==0;
 assign sc_clk=pixel_clk;
 // One-cycle synchronous read, preload the next horizontal pixel.
 assign wave_address=h>=15 && h<527 ? h-15 : 9'd0;
 reg [4:0] key_index;reg [5:0] key_x;
 always @(posedge pixel_clk or negedge rst_n) begin
 if(!rst_n) begin h<=0;v<=0;frame<=0;key_index<=0;key_x<=0;end
 else begin
 if(frame_start) frame<=status;
 if(h==1055) begin h<=0;v<=v==524 ? 0 : v+1'b1;end else h<=h+1'b1;
 if(h<3 || h>=795) begin key_index<=0;key_x<=0;end
 else if(key_x==32) begin key_index<=key_index+1'b1;key_x<=0;end
 else key_x<=key_x+1'b1;
 end end
 function [7:0] digit;
 input [15:0] n;input [1:0] place;
 begin case(place) 2:digit=48+(n/100)%10;1:digit=48+(n/10)%10;default:digit=48+n%10;endcase end endfunction
 function [7:0] character;
 input [4:0] row;input [5:0] col;
 reg [399:0] line;
 begin
 line=0;
 case(row)
0:line=" PIANO        VOL 000    VOICES 00/32    ERR 000  ";
2:line=" WAVEFORM 21MS                    PARAMETERS      ";
4:line="                                 KEY 00 NOTE 000  ";
6:line="                                 VELOCITY 000     ";
8:line="                                 STRIKE NONE      ";
10:line="                                 BEND N/A         ";
12:line="                                 VIBRATO N/A      ";
14:line="                                 GLIDE OFF 300MS  ";
16:line="                                 FX MIX 000/127   ";
18:line="                                 PAGE GLIDE       ";
20:line="                                 SHORT NEXT       ";
21:line="                                 HOLD ACTION      ";
23:line="                                 TEST OFF         ";
26:line=" SONG 1  STOP   STEP 00/16   BEAT 1   BPM 120     ";
28:line=" PRESS TARGET  RELEASE REPEATS  HOLD RESTART      ";
 default:line=0;
 endcase
 character=col<50 ? line[399-col*8-:8] : 0;
 if(row==0) begin
 if(instrument!=0 && col>=1 && col<=5) begin case(col) 1:character="B";2:character="E";3,4:character="L";5:character=" ";endcase end
 case(col)
 18:character=digit(volume,2);
 19:character=digit(volume,1);
 20:character=digit(volume,0);
 32:character=digit(voices,1);
 33:character=digit(voices,0);
 45:character=digit(errors,2);
 46:character=digit(errors,1);
 47:character=digit(errors,0);
 endcase
 end
 if(row==4) case(col)
 37:character=digit(key+1,1);38:character=digit(key+1,0);
 45:character=digit(note,2);46:character=digit(note,1);47:character=digit(note,0);
 endcase
 if(row==6 && col>=42 && col<=44) character=digit(velocity,44-col);
 if(row==8 && col>=40 && col<=43) begin case(col) 40:character=velocity==0 ? "N" : velocity<=32 ? "S" : "H";41:character=velocity==0 ? "O" : velocity<=32 ? "O" : "A";42:character=velocity==0 ? "N" : velocity<=32 ? "F" : "R";43:character=velocity==0 ? "E" : velocity<=32 ? "T" : "D";endcase end
 if(row==14) begin
 if(col==39) character="O";if(col==40) character=enabled ? "N" : "F";if(col==41) character=enabled ? " " : "F";
 if(col>=43 && col<=45) character=digit(glide_ms,45-col);
 end
 if(row==16 && col>=40 && col<=42) character=digit(fx,42-col);
 if(row==18 && col>=38 && col<=42) begin
 case(menu)
 0:case(col) 38:character="G";39:character="L";40:character="I";41:character="D";42:character="E";endcase
 1:character=col==38 ? "F" : col==39 ? "X" : " ";
 2:case(col) 38:character="S";39:character="O";40:character="N";41:character="G";42:character=" ";endcase
 3:case(col) 38:character="T";39:character="E";40:character="M";41:character="P";42:character="O";endcase
 4:case(col) 38:character="T";39:character="E";40:character="S";41:character="T";42:character=" ";endcase
 endcase end
 if(row==23 && frame[148]) begin
 if(col==38) character="O";if(col==39) character="N";if(col==40) character=" ";
 end
 if(row==26) begin
 if(col==6) character=song ? "2" : "1";
 if(col>=9 && col<=12) case(col) 9:character=running ? "P" : "S";10:character=running ? "L" : "T";11:character=running ? "A" : "O";12:character=running ? "Y" : "P";endcase
 if(col==20 || col==21) character=digit(running ? position+1 : position,col==20 ? 1 : 0);
 if(col==24 || col==25) character=digit(song ? 16 : 14,col==24 ? 1 : 0);
 if(col==34) character=digit(beat+1,0);
 if(col>=42 && col<=44) character=digit(tempo,44-col);
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
 default:glyph=0;
 endcase end endfunction
 wire [7:0] char_code=character(v[8:4],h[9:4]);
 wire [34:0] bitmap=glyph(char_code);
 wire text_hit=h[3:1]<5 && v[3:1]<7 && bitmap[34-v[3:1]*5-h[3:1]];
 // The audio path supplies a signed 16-bit display sample.  Use four-times
 // vertical gain for readability, then clamp to the waveform panel so a loud
 // chord cannot paint outside its area. This affects the LCD only.
 function signed [17:0] waveform_y;
 input signed [15:0] value;
 reg signed [17:0] y;
 begin
 y=18'sd208-($signed(value) >>> 6);
 if(y<18'sd80) y=18'sd80;
 else if(y>18'sd336) y=18'sd336;
 waveform_y=y;
 end
 endfunction
 wire signed [17:0] high_y=waveform_y(wave_max);
 wire signed [17:0] low_y=waveform_y(wave_min);
 reg [5:0] r,g,b,rp,gp,bp;reg hp,vp,dp;
 always @* begin
 r=5;g=9;b=13;
 if(h>=16 && h<528 && v>=80 && v<336) begin
 r=3;g=5;b=8;
 if(v==208 || h[6:0]==16) begin r=8;g=14;b=19;end
 if(wave_ready && $signed({1'b0,v})>=high_y && $signed({1'b0,v})<=low_y) begin r=10;g=60;b=38;end
 end
 if(v>=352 && v<410 && h>=4 && h<796 && key_index<24 && key_x<30) begin
 r=52;g=55;b=55;
 if(guides[key_index]) begin r=12;g=32;b=63;end
 if(keys[key_index]) begin r=8;g=58;b=30;end
 end
 if(v>=414 && v<420 && h>=16 && h<16+{position,5'b0}) begin r=12;g=48;b=60;end
 if(text_hit && !(h<528 && v>=80 && v<336) && !(v>=352 && v<410)) begin r=58;g=60;b=61;end
 if(v<16 && errors!=0 && h>=624) begin if(text_hit) begin r=63;g=14;b=8;end end
 end
 always @(posedge pixel_clk or negedge rst_n) begin
 if(!rst_n) begin rp<=0;gp<=0;bp<=0;hp<=1;vp<=1;dp<=0;end
 else begin rp<=r;gp<=g;bp<=b;hp<=!(h>=840 && h<968);vp<=!(v>=493 && v<495);dp<=active;end end
 always @(negedge pixel_clk or negedge rst_n) begin
 if(!rst_n) begin r_out<=0;g_out<=0;b_out<=0;sc_hs<=1;sc_vs<=1;sc_de<=0;end
 else begin r_out<=rp;g_out<=gp;b_out<=bp;sc_hs<=hp;sc_vs<=vp;sc_de<=dp;end end
 endmodule

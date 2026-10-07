// Guide only; no synthesized or recorded audio is played by the score.
module lesson_guide(input wire clk,rst_n,sample_tick,toggle,song,
 input wire [7:0] tempo, output reg running, output reg [4:0] position,
 output reg [1:0] beat, output reg [23:0] guide_keys);
 reg [21:0] phase;reg previous_song;
 function [4:0] key_for;
 input song_id;input [4:0] pos;
 begin
 if(!song_id) case(pos[3:0])
 0,1,14,15:key_for=0;2,3:key_for=7;4,5:key_for=9;6:key_for=7;
 7,8:key_for=5;9,10:key_for=4;11,12:key_for=2;default:key_for=0;
 endcase
 else case(pos[3:0])
 0,1,2:key_for=4;3:key_for=2;4:key_for=0;5:key_for=2;
 6:key_for=4;7:key_for=5;8,9:key_for=7;10:key_for=5;
 11:key_for=4;12:key_for=2;13:key_for=0;14:key_for=2;default:key_for=0;
 endcase
 end endfunction
 always @* guide_keys=running ? (24'd1 << key_for(song,position)) : 0;
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin running<=0;position<=0;beat<=0;phase<=0;previous_song<=0;end
 else begin
 previous_song<=song;
 if(song!=previous_song) begin running<=0;position<=0;beat<=0;phase<=0;end
 else if(toggle) begin running<=~running;if(position==16) begin position<=0;beat<=0;phase<=0;end end
 else if(sample_tick && running) begin
 if(phase+tempo>=2880000) begin
 phase<=phase+tempo-2880000;beat<=beat+1'b1;
 if(position==15) begin position<=16;running<=0;end else position<=position+1'b1;
 end else phase<=phase+tempo;
 end
 end end
endmodule

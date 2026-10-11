// Physical-key practice guide. The score never injects audio events.
module lesson_guide(
 input wire clk,rst_n,song_mode,toggle,song,
 input wire [23:0] keys,
 output reg running, output reg [4:0] position,
 output reg [1:0] beat, output wire [23:0] guide_keys);
 reg previous_mode,previous_song;
 reg [23:0] previous_keys;
 wire [23:0] pressed=keys & ~previous_keys;
 wire [4:0] last_position=song ? 5'd15 : 5'd13;
 function [4:0] key_for;
 input song_id; input [4:0] pos;
 begin
  if(!song_id) case(pos)
   // Twinkle Little Star opening: C C G G A A G | F F E E D D C.
   0,1,13:key_for=0; 2,3,6:key_for=7; 4,5:key_for=9;
   7,8:key_for=5; 9,10:key_for=4; 11,12:key_for=2;
   default:key_for=0;
  endcase else case(pos)
   0,1,2:key_for=4; 3:key_for=2; 4:key_for=0; 5:key_for=2;
   6:key_for=4; 7:key_for=5; 8,9:key_for=7; 10:key_for=5;
   11:key_for=4; 12:key_for=2; 13:key_for=0; 14:key_for=2; default:key_for=0;
  endcase
 end endfunction
 assign guide_keys=song_mode && running ? (24'd1<<key_for(song,position)) : 24'd0;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin running<=0;position<=0;beat<=0;previous_mode<=0;previous_song<=0;previous_keys<=0; end
  else begin
   previous_mode<=song_mode; previous_song<=song; previous_keys<=keys;
   if(!song_mode) begin running<=0;position<=0;beat<=0;end
   else if(!previous_mode || song!=previous_song || toggle) begin running<=1;position<=0;beat<=0;end
   else if(running && pressed[key_for(song,position)]) begin
    beat<=beat+1'b1;
    if(position==last_position) begin position<=last_position+1'b1;running<=0;end
    else position<=position+1'b1;
   end
  end
 end
endmodule

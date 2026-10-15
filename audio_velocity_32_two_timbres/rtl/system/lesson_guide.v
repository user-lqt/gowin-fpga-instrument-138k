// BLE-selected physical-key guide. No score-generated audio events.
// Slot 3 stays unavailable until a score is selected.
module lesson_guide(
 input wire clk,rst_n,song_mode,select_valid,
 input wire sample_tick,rhythm_enabled,local_start,
 input wire [1:0] local_song,
 input wire [7:0] tempo,user_length,user_key,user_duration,
 input wire user_ready,
 output wire [6:0] score_address,
 output reg count_in,beat_flash,
 output reg [2:0] timing_grade,
 output reg [9:0] correct_count,miss_count,
 input wire [1:0] select_song,
 input wire [23:0] keys,
 output reg running,complete,unavailable,
 output reg [1:0] song,
 output reg [9:0] position,
 output wire [9:0] total,
 output reg [1:0] beat,
 output wire [23:0] guide_keys);
 reg previous_mode;
 reg previous_rhythm;
 reg [23:0] previous_keys;
 wire [23:0] pressed=keys & ~previous_keys;
 function [9:0] score_length;
 input [1:0] id;
 begin case(id)
  1:score_length=54;
  2:score_length=60;
  default:score_length=0;
 endcase end
 endfunction
 // Jasmine: simplified single-note C-major practice arrangement.
 // K1=C, K3=D, K5=E, K8=G, K10=A, K13=upper C.
 // K6 is never a score target. Index is zero based.
 function [4:0] key_for;
 input [1:0] id; input [9:0] pos;
 begin
 key_for=0;
 if(id==1) case(pos)
  0,1,11,12,25,30,32,34,44,48,52:key_for=4;
  2,7,8,10,13,18,19,21,22,23,24,26,29,33,45,49:key_for=7;
  3,6,9,14,17,20,27,28,46:key_for=9;
  4,5,15,16,47:key_for=12;
  31,35,38,40,43,50,51:key_for=2;
  default:key_for=0;
 endcase
 else if(id==2) key_for=fingerprint_key(pos);
 end
 endfunction
// Fingerprint chorus only: pickup + one chorus + first ending.
// Original score indices 116..175; transposed B->A, no K6.
 function [4:0] fingerprint_key;
 input [9:0] pos;
 begin case(pos)
  10'd12,10'd17,10'd27,10'd44:fingerprint_key=5'd4;
  10'd4,10'd8,10'd13,10'd21,10'd31,10'd35,10'd40,10'd48,10'd52,10'd56:fingerprint_key=5'd6;
  10'd36:fingerprint_key=5'd8;
  10'd3,10'd7,10'd11,10'd16,10'd20,10'd25,10'd30,10'd34,10'd43,10'd47,10'd55,10'd57,10'd58:fingerprint_key=5'd9;
  10'd1,10'd2,10'd6,10'd10,10'd14,10'd15,10'd18,10'd19,10'd23,10'd24,10'd26,10'd28,10'd29,10'd33,10'd41,10'd42,10'd45,10'd46,10'd49,10'd50,10'd51:fingerprint_key=5'd11;
  10'd5,10'd9,10'd22,10'd32,10'd54:fingerprint_key=5'd13;
  10'd53:fingerprint_key=5'd14;
  10'd0,10'd59:fingerprint_key=5'd16;
  10'd37,10'd39:fingerprint_key=5'd21;
  10'd38:fingerprint_key=5'd23;
  default:fingerprint_key=0;
 endcase end
 endfunction
 assign total=song==3 ? (user_ready ? {2'd0,user_length} : 10'd0) : score_length(song);
 assign score_address=position[6:0];
 wire rest=song==3 && user_key==0;
 wire [4:0] target=song==3 ? user_key-1'b1 : key_for(song,position);
 // Built-ins are simplified practice timings in eighth-note units.
 // Uploaded scores carry an explicit duration (1..32) for every note/rest.
 function [7:0] builtin_duration;
 input [1:0] id;input [9:0] pos;
 begin
 builtin_duration=2;
 if(id==1) case(pos)
 0,1,2,3,4,5,11,12,13,14,15,16:builtin_duration=1;
 10,21,35,43,53:builtin_duration=4;
 endcase
 else if(id==2) begin
 builtin_duration=1;
 case(pos)
 3,7,11,16,20,25,30,34,39,43,47,51,58:builtin_duration=2;
 59:builtin_duration=8;
 endcase end
 end endfunction
 wire [7:0] duration=song==3 ? user_duration : builtin_duration(song,position);
 reg [5:0] slot_units;
 reg [28:0] elapsed;
 reg [21:0] beat_phase;
 reg [12:0] flash_samples;
 reg [3:0] preparation;
 reg hit_this_note;
 wire eighth_tick=sample_tick && beat_phase+tempo>=1440000;
 wire mode_changed=running && previous_rhythm!=rhythm_enabled;
 wire starting=select_valid || local_start || mode_changed;
 wire [1:0] requested=select_valid ? select_song : local_start ? local_song : song;
 wire available=requested==3 ? user_ready : score_length(requested)!=0;
 assign guide_keys=!song_mode ? 24'd0 : complete ? 24'hFFFFFF :
                   running && !count_in && !rest ? (24'd1<<target) : 24'd0;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   running<=0;complete<=0;unavailable<=0;song<=0;
   position<=0;beat<=0;previous_mode<=0;previous_keys<=0;previous_rhythm<=0;
   count_in<=0;beat_flash<=0;timing_grade<=0;correct_count<=0;miss_count<=0;
   elapsed<=0;beat_phase<=0;flash_samples<=0;preparation<=0;hit_this_note<=0;slot_units<=0;
  end else begin
   previous_mode<=song_mode;previous_keys<=keys;previous_rhythm<=rhythm_enabled;
   if(sample_tick) begin
    if(flash_samples!=0) begin flash_samples<=flash_samples-1'b1;beat_flash<=1;end
    else beat_flash<=0;
    if(running && rhythm_enabled) begin
     if(eighth_tick) begin
      beat_phase<=beat_phase+tempo-1440000;beat<=beat+1'b1;
      if(!beat[0]) flash_samples<=2400;
     end else beat_phase<=beat_phase+tempo;
    end
   end
   if(!song_mode || (!previous_mode && !starting)) begin
    running<=0;complete<=0;unavailable<=0;song<=0;position<=0;beat<=0;
    count_in<=0;elapsed<=0;beat_phase<=0;timing_grade<=0;beat_flash<=0;flash_samples<=0;slot_units<=0;
   end else if(starting && requested>=1 && requested<=3) begin
    song<=requested;position<=0;beat<=0;complete<=0;elapsed<=0;beat_phase<=0;slot_units<=0;
    running<=available;unavailable<=!available;
    count_in<=rhythm_enabled && available;preparation<=0;hit_this_note<=0;
    timing_grade<=0;correct_count<=0;miss_count<=0;
    flash_samples<=rhythm_enabled && available ? 2400 : 0;
   end else if(running) begin
    if(!rhythm_enabled) begin
     count_in<=0;
     if(rest || pressed[target]) begin
      if(!rest) correct_count<=correct_count+1'b1;
      beat<=beat+1'b1;
      if(position+10'd1==total) begin position<=total;running<=0;complete<=1;end
      else position<=position+1'b1;
     end
    end else if(count_in) begin
     if(|pressed) timing_grade<=1; // EARLY: during preparation
     if(eighth_tick) begin
      if(preparation==7) begin count_in<=0;elapsed<=0;timing_grade<=0;beat<=0;slot_units<=0;end
      else preparation<=preparation+1'b1;
     end
    end else begin
     if(!rest && !hit_this_note && pressed[target]) begin
      hit_this_note<=1;
      if(elapsed<=7200) begin timing_grade<=2;correct_count<=correct_count+1'b1;end
      else timing_grade<=3; // LATE: over 150 ms after onset
     end
     if(sample_tick) begin
      if(eighth_tick && slot_units+1>=duration) begin
       elapsed<=0;hit_this_note<=0;slot_units<=0;
       if(!rest && !hit_this_note && !pressed[target]) begin
        miss_count<=miss_count+1'b1;timing_grade<=4;
       end
       if(position+10'd1==total) begin position<=total;running<=0;complete<=1;end
       else position<=position+1'b1;
      end else begin elapsed<=elapsed+1'b1;if(eighth_tick) slot_units<=slot_units+1'b1;end
     end
    end
   end
  end
 end
endmodule

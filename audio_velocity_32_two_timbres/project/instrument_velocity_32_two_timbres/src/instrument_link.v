`include "event_defs.vh"
// Control protocol + volatile score3 + key mapping + event recording + UART TX.
// Every reply is a 12-byte A6 packet; see EXTENSIONS_PROTOCOL.md.
module instrument_link #(parameter integer CLK_HZ=12288000,BAUD=115200)(
 input wire clk,rst_n,sample_tick,command_valid,
 input wire [7:0] command,a,b,
 input wire [23:0] keys,
 input wire keyboard_valid,input wire [1:0] keyboard_type,
 input wire [6:0] keyboard_note,input wire [7:0] keyboard_velocity,
 output reg mapped_valid,output reg [1:0] mapped_type,
 output reg [6:0] mapped_note,output reg [7:0] mapped_velocity,
 input wire record_valid,input wire [1:0] record_type,
 input wire [6:0] record_note,input wire [7:0] record_velocity,
 input wire lesson_running,song_mode,input wire [6:0] score_address,
 output wire [7:0] score_key,score_duration,
 output reg [7:0] score_length,output reg score_ready,
 output reg rhythm_enabled,output reg [7:0] remote_tempo,output reg tempo_valid,
 output reg recording,output reg [9:0] record_count,
 output reg record_overflow,output wire dumping,output reg reply_overflow,
 output wire tx);
 reg [6:0] mapping[0:23],held_note[0:23];
 reg [23:0] held;
 wire [4:0] key_index=keyboard_note-7'd60;
 reg [15:0] score_ram[0:127];
 assign {score_key,score_duration}=score_ram[score_address];
 reg uploading;reg [7:0] expected,received;
 reg [47:0] recording_ram[0:511];
 reg [47:0] read_record;
 reg [9:0] dump_index;
 reg [2:0] dump_state;
 assign dumping=dump_state!=0;
 reg [5:0] ms_div;reg [31:0] time_ms;
 reg [31:0] responses[0:7];reg [2:0] qrd,qwr;reg [3:0] qcount;
 reg [31:0] response;
 reg push;reg [7:0] result;reg [15:0] detail;
 reg [95:0] packet;
 reg packet_busy,byte_busy;
 reg [3:0] packet_index,bit_index;
 reg [15:0] baud_count;
 reg tx_reg;
 assign tx=tx_reg;
 localparam integer CPB=(CLK_HZ+BAUD/2)/BAUD;
 integer i,j,n;reg [2:0] w;reg duplicate;
 function [95:0] make_packet;
 input [7:0] kind;input [71:0] payload;
 reg [95:0] p;reg [7:0] check;integer x;
 begin
 p={8'd0,payload,kind,8'hA6};check=0;
 for(x=0;x<11;x=x+1) check=check^p[x*8+:8];
 p[95:88]=check;make_packet=p;
 end endfunction
 // Single synchronous read port for efficient block RAM inference.
 always @(posedge clk) begin
 read_record<=recording_ram[dump_index[8:0]];
 if(rst_n && recording && record_valid && record_count<512)
 recording_ram[record_count[8:0]]<={time_ms,record_type,record_note,record_velocity[6:0]};
 end
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
 mapped_valid<=0;mapped_type<=0;mapped_note<=0;mapped_velocity<=0;held<=0;
 for(i=0;i<24;i=i+1) begin mapping[i]<=60+i;held_note[i]<=60+i;end
 score_length<=0;score_ready<=0;uploading<=0;expected<=0;received<=0;
 rhythm_enabled<=0;remote_tempo<=120;tempo_valid<=0;
 recording<=0;record_count<=0;record_overflow<=0;dump_index<=0;dump_state<=0;
 ms_div<=0;time_ms<=0;qrd<=0;qwr<=0;qcount<=0;reply_overflow<=0;
 packet<=0;packet_busy<=0;packet_index<=0;byte_busy<=0;bit_index<=0;baud_count<=0;tx_reg<=1;
 end else begin
 mapped_valid<=0;tempo_valid<=0;
 if(sample_tick) begin
 if(ms_div==47) begin ms_div<=0;if(recording) time_ms<=time_ms+1'b1;end
 else ms_div<=ms_div+1'b1;
 end
 if(keyboard_valid && keyboard_note>=60 && keyboard_note<84) begin
 mapped_valid<=1;mapped_type<=keyboard_type;mapped_velocity<=keyboard_velocity;
 if(keyboard_type==`EVENT_NOTE_ON) begin
 mapped_note<=mapping[key_index];held_note[key_index]<=mapping[key_index];held[key_index]<=1;
 end else begin mapped_note<=held_note[key_index];held[key_index]<=0;end
 end
 if(recording && record_valid) begin
 if(record_count<512) record_count<=record_count+1'b1;
 else begin record_overflow<=1;recording<=0;end
 end
 push=0;result=0;detail=0;
 if(command_valid && command!=8'h90 && command!=8'h80) begin
 push=1;
 if((command==8'hC3 || command==8'hD1 || command==8'hE0 || command==8'hE1 || command==8'hE2 || command==8'hF0) && (a!=0 || b!=0)) result=2;
 else case(command)
 8'hB0:if(!song_mode) result=3;else if(a==0 || a>3 || b!=0) result=2;else if(a==3 && !score_ready) result=4;
 8'hB1:if(lesson_running) result=3;else if(a<=1 && b==0) rhythm_enabled<=a[0];else result=2;
 8'hB2:if(lesson_running) result=3;else if(a>=40 && a<=200 && b==0) begin remote_tempo<=a;tempo_valid<=1;end else result=2;
 8'hC0:begin
 if(lesson_running || uploading) result=3;
 else if(a==0 || a>128 || b!=0) result=2;
 else begin uploading<=1;expected<=a;received<=0;score_ready<=0;end
 end
 8'hC1:begin
 if(!uploading) result=4;
 else if(received>=expected || a>24 || a==6 || b==0 || b>32) result=2;
 else begin score_ram[received[6:0]]<={a,b};received<=received+1'b1;detail=received+1'b1;end
 end
 8'hC2:begin
 if(a!=0 || b!=0) result=2;
 else if(!uploading || received!=expected) result=4;
 else begin score_length<=expected;score_ready<=1;uploading<=0;detail=expected;end
 end
 8'hC3:begin uploading<=0;end
 8'hD0:begin
 duplicate=0;
 for(j=0;j<24;j=j+1) if(j!=a-1 && mapping[j]==b) duplicate=1;
 if(a==0 || a>24 || b>127 || duplicate) result=2;
 else if(|keys || |held) result=3;
 else mapping[a-1]<=b[6:0];
 end
 8'hD1:if(|keys || |held) result=3;else for(j=0;j<24;j=j+1) mapping[j]<=60+j;
 8'hE0:if(dumping) result=3;else begin recording<=1;record_count<=0;record_overflow<=0;time_ms<=0;ms_div<=0;end
 8'hE1:begin recording<=0;detail=record_count;end
 8'hE2:if(recording || dumping) result=3;else begin dump_index<=0;dump_state<=1;detail=record_count;end
 8'hF0:begin detail={2'd0,reply_overflow,record_overflow,dumping,recording,record_count};end
 default:result=1;
 endcase
 end
 // Queue command replies; record packets only start between complete replies.
 n=qcount;w=qwr;
 if(!packet_busy && qcount!=0) begin
 response=responses[qrd];qrd<=qrd+1'b1;n=n-1;
 packet<=make_packet(8'hF0,{40'd0,response});packet_busy<=1;packet_index<=0;
 end else if(!packet_busy && dump_state==2) begin
 if(dump_index==record_count) begin
 packet<=make_packet(8'hE1,{48'd0,7'd0,record_overflow,6'd0,record_count});
 packet_busy<=1;packet_index<=0;dump_state<=0;
 end else begin
 packet<=make_packet(8'hE0,{6'd0,dump_index,read_record[47:16],1'b0,read_record[6:0],1'b0,read_record[13:7],6'd0,read_record[15:14]});
 packet_busy<=1;packet_index<=0;dump_index<=dump_index+1'b1;dump_state<=1;
 end
 end
 if(dump_state==1) dump_state<=2;
 if(push) begin
 if(n<8) begin responses[w]<={detail,result,command};w=w+1'b1;n=n+1;end
 else reply_overflow<=1;
 end
 qwr<=w;qcount<=n;
 // UART LSB first, start + 8 data + stop. No changes to audio timing.
 if(packet_busy && !byte_busy) begin
 byte_busy<=1;bit_index<=0;baud_count<=CPB-1;tx_reg<=0;
 end else if(byte_busy) begin
 if(baud_count!=0) baud_count<=baud_count-1'b1;
 else begin
 baud_count<=CPB-1;
 if(bit_index<8) begin tx_reg<=packet[packet_index*8+bit_index];bit_index<=bit_index+1'b1;end
 else if(bit_index==8) begin tx_reg<=1;bit_index<=9;end
 else begin
 byte_busy<=0;
 if(packet_index==11) packet_busy<=0;else packet_index<=packet_index+1'b1;
 end
 end end
 end end
endmodule

`include "event_defs.vh"
// The real allocator receives one event per audio frame. No PCM is stored.
module polyphony_test #(
 parameter integer VOICES=32,
 parameter integer SELECT_SAMPLES=9600,
 // Also exceed the 6144-frame normal FX delay before restoring its output.
 parameter integer SETTLE_SAMPLES=6400
)(input wire clk,rst_n,sample_tick,toggle,
 input wire [6:0] selection,
 input wire keyboard_valid,input wire [1:0] keyboard_type,
 input wire [6:0] keyboard_note,input wire [7:0] keyboard_velocity,
 input wire [23:0] keys,
 output wire active,output wire ready,
 output reg [6:0] applied_selection,output reg [6:0] expected_count,
 output reg event_valid,output reg [1:0] event_type,
 output reg [6:0] note_id,output reg [7:0] velocity);
 localparam NORMAL=0,DRAIN=1,CLEAR=2,TAIL=3,UPDATE=4,SETTLE=5,HOLD=6,WAIT_KEYS=7;
 reg [2:0] state;
 reg [6:0] index;
 reg desired;
 reg [15:0] timer,select_timer;
 reg [6:0] observed_selection,stable_selection;
 reg [VOICES-1:0] current_mask,target_mask;
 reg [VOICES-1:0] selected_mask;
 reg [6:0] selected_count;
 integer k;
 always @* begin
 selected_mask=0;
 // Selection categories have fixed populations; avoid a VOICES-deep adder.
 if(stable_selection==0) selected_count=VOICES;
 else if(stable_selection<=4) selected_count=VOICES/4;
 else if(stable_selection<=VOICES+4) selected_count=VOICES-1;
 else selected_count=0;
 for(k=0;k<VOICES;k=k+1) begin
 if(stable_selection==0 ||
    (stable_selection>=1 && stable_selection<=4 &&
     k/(VOICES/4)==stable_selection-1) ||
    (stable_selection>=5 && stable_selection<=VOICES+4 && k!=stable_selection-5)) begin
 selected_mask[k]=1;
 end
 end
 end
 assign active=state!=NORMAL;
 // A pending encoder choice is not a stable acquisition, even before debounce.
 assign ready=state==HOLD && selection==applied_selection &&
     observed_selection==applied_selection && stable_selection==applied_selection;
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
 state<=NORMAL;index<=0;desired<=0;event_valid<=0;event_type<=0;note_id<=0;velocity<=0;
 timer<=0;select_timer<=0;observed_selection<=0;stable_selection<=0;
 applied_selection<=0;expected_count<=0;current_mask<=0;target_mask<=0;
 end else begin
 event_valid<=0;
 if(sample_tick) begin
 if(selection!=observed_selection) begin observed_selection<=selection;select_timer<=0;end
 else if(select_timer<SELECT_SAMPLES) select_timer<=select_timer+1'b1;
 else stable_selection<=observed_selection<=VOICES+4 ? observed_selection : 7'd0;
 end
 if(toggle) begin
 desired<=!desired;state<=DRAIN;index<=0;timer<=0;expected_count<=0;
 end else if(state==NORMAL) begin
 event_valid<=keyboard_valid;event_type<=keyboard_type;note_id<=keyboard_note;velocity<=keyboard_velocity;
 end else if(sample_tick) begin
 case(state)
 // Drain bounded upstream/core FIFOs before the all-notes-off sweep.
 DRAIN:if(timer==127) begin timer<=0;index<=0;state<=CLEAR;end else timer<=timer+1'b1;
 CLEAR:begin
 event_valid<=1;event_type<=`EVENT_NOTE_OFF;note_id<=index;velocity<=0;
 if(index==127) begin index<=0;timer<=0;current_mask<=0;state<=TAIL;end
 else index<=index+1'b1;
 end
 TAIL:if(timer==SETTLE_SAMPLES-1) begin
 timer<=0;
 if(desired) begin
 target_mask<=selected_mask;applied_selection<=stable_selection;
 expected_count<=selected_count;state<=UPDATE;
 end else state<=WAIT_KEYS;
 end else timer<=timer+1'b1;
 UPDATE:begin
 if(current_mask[index]!=target_mask[index]) begin
 event_valid<=1;event_type<=target_mask[index] ? `EVENT_NOTE_ON : `EVENT_NOTE_OFF;
 note_id<=7'd48+index;velocity<=target_mask[index] ? 8'd64 : 8'd0;
 current_mask[index]<=target_mask[index];
 end
 if(index==VOICES-1) begin index<=0;timer<=0;state<=SETTLE;end else index<=index+1'b1;
 end
 SETTLE:if(timer==SETTLE_SAMPLES-1) begin state<=HOLD;timer<=0;end else timer<=timer+1'b1;
 HOLD:if(stable_selection!=applied_selection) begin
 target_mask<=selected_mask;applied_selection<=stable_selection;
 expected_count<=selected_count;index<=0;state<=UPDATE;
 end
 WAIT_KEYS:if(keys==0) state<=NORMAL;
 default:state<=NORMAL;
 endcase
 end
 end end
endmodule

`include "event_defs.vh"
// One event per sample period; clear all MIDI notes on either transition.
module polyphony_test(input wire clk,rst_n,sample_tick,toggle,
 input wire keyboard_valid,input wire [1:0] keyboard_type,
 input wire [6:0] keyboard_note,input wire [7:0] keyboard_velocity,
 input wire [23:0] keys,
 output wire active,output reg event_valid,output reg [1:0] event_type,
 output reg [6:0] note_id,output reg [7:0] velocity);
 reg [2:0] state;
 reg [6:0] index;
 reg desired;
 localparam NORMAL=0,CLEAR=1,LOAD=2,HOLD=3,WAIT_KEYS=4;
 assign active=state!=NORMAL;
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin state<=NORMAL;index<=0;desired<=0;event_valid<=0;event_type<=0;note_id<=0;velocity<=0;end
 else begin
 event_valid<=0;
 if(toggle) begin desired<=!desired;state<=CLEAR;index<=0;end
 else if(state==NORMAL) begin
 event_valid<=keyboard_valid;event_type<=keyboard_type;note_id<=keyboard_note;velocity<=keyboard_velocity;
 end else if(sample_tick) begin
 case(state)
 CLEAR:begin
 event_valid<=1;event_type<=`EVENT_NOTE_OFF;note_id<=index;velocity<=0;
 if(index==127) begin index<=0;state<=desired ? LOAD : WAIT_KEYS;end
 else index<=index+1'b1;
 end
 LOAD:begin
 event_valid<=1;event_type<=`EVENT_NOTE_ON;note_id<=7'd48+index;velocity<=8'd64;
 if(index==31) state<=HOLD;else index<=index+1'b1;
 end
 WAIT_KEYS:if(keys==0) state<=NORMAL;
 default:;
 endcase
 end
 end end
endmodule

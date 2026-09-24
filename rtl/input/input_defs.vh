`ifndef MUSIC_INPUT_DEFS_VH
`define MUSIC_INPUT_DEFS_VH
// B-side provisional protocol; coordinate with C's event_defs.vh before merge.
`define EVENT_NOTE_ON       2'b00
`define EVENT_NOTE_OFF      2'b01
`define EVENT_PARAM_CHANGE  2'b10
// Provisional B-side parameter ID; align with A/C before system integration.
`define PARAM_VOLUME        4'h0
`define PARAM_INSTRUMENT    4'h1
// Reserved protocol IDs: not produced by the B0/B1/B2 baseline.
`define PARAM_PITCH_BEND    4'h2
`define PARAM_MODULATION    4'h3
`define PARAM_FILTER        4'h4
`define PARAM_EFFECT_MIX    4'h5
`define INPUT_PROTOCOL_VERSION 8'h01
`endif

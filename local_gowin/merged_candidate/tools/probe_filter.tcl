set ROOT [file dirname [file dirname [file normalize [info script]]]]
cd $ROOT
set variant [lindex $argv 0]
 create_project -name filter_$variant -dir $ROOT/diagnostics/projects -pn GW5AST-LV138PG484AC1/I0 -device_version C -force
 if {$variant == "before"} {add_file $ROOT/diagnostics/velocity_before/audio_core/guitar_body_tone_bank.v} else {add_file $ROOT/rtl/audio_core/guitar_body_tone_bank.v}
 set_option -top_module guitar_body_tone_bank
 run syn

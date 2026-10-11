set ROOT [file dirname [file dirname [file normalize [info script]]]]
cd $ROOT
create_project -name guitar_before -dir $ROOT/diagnostics/projects -pn GW5AST-LV138PG484AC1/I0 -device_version C -force
add_file $ROOT/diagnostics/velocity_before/audio_core/plucked_string.v
set_option -top_module plucked_string
run syn

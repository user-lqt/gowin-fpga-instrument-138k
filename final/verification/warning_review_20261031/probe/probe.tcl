set ROOT [file dirname [file normalize [info script]]]
create_project -name warning_probe -dir $ROOT -pn GW5AST-LV138PG484AC1/I0 -device_version C
add_file $ROOT/warning_probe_top.v
set_option -top_module warning_probe_top
set_option -output_base_name warning_probe
run syn
puts "BUILD STAGE COMPLETE syn"

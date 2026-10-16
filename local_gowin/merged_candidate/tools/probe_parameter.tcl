set ROOT [file dirname [file dirname [file normalize [info script]]]]
cd $ROOT
create_project -name parameter_after -dir $ROOT/diagnostics/projects -pn GW5AST-LV138PG484AC1/I0 -device_version C -force
add_file $ROOT/rtl/ui/parameter_manager.v
set_option -top_module parameter_manager
run syn

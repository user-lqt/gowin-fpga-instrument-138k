set ROOT {E:/GowinProjects/synth_top}
cd $ROOT
create_project -name sim_scheduler -dir $ROOT/sim -pn GW5AST-LV138PG484AC1/I0 -device_version C -force
add_file $ROOT/rtl/system/sample_scheduler.v
add_file $ROOT/tb/tb_scheduler.v
set_option -top_module tb_scheduler
puts "=== project ready, running simulation ==="
run all
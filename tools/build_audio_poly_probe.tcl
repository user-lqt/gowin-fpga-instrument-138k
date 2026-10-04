# Fixed two-note diagnostic, separate from the live keyboard and A4 baselines.
set ROOT {E:/GowinProjects/synth_top}
set DEVICE {GW5AST-LV138PG484AC1/I0}
cd $ROOT
create_project -name audio_poly_probe_top -dir $ROOT/project -pn $DEVICE -device_version {C} -force
add_file $ROOT/rtl/common/reset_sync.v
add_file $ROOT/rtl/system/clock_gen.v
add_file $ROOT/rtl/system/sample_scheduler.v
add_file $ROOT/rtl/system/i2s_tx_official.v
foreach src [glob $ROOT/rtl/audio_core/*.v] { add_file $src }
add_file $ROOT/project/audio_poly_probe_top.v
add_file $ROOT/constraint/tang_mega138k.cst
add_file $ROOT/constraint/tang_mega138k.sdc
set_option -top_module audio_poly_probe_top
run syn
run pnr

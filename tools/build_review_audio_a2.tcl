# Isolated integration review of A's 359f090 (tick_sr declaration moved earlier).
set ROOT {E:/GowinProjects/synth_top}
set AUDIO_ROOT {E:/GowinProjects/synth_top_a2_review_359f090}
cd $ROOT
create_project -name instrument_a2_review -dir $ROOT/project -pn {GW5AST-LV138PG484AC1/I0} -device_version {C} -force
add_file $ROOT/rtl/common/reset_sync.v
add_file $ROOT/rtl/system/clock_gen.v
add_file $ROOT/rtl/system/sample_scheduler.v
add_file $ROOT/rtl/system/i2s_tx_official.v
add_file $ROOT/rtl/system/system_status.v
foreach src [glob $AUDIO_ROOT/rtl/audio_core/*.v] { add_file $src }
foreach src [glob $ROOT/rtl/input/*.v] { add_file $src }
foreach src [glob $ROOT/rtl/ui/*.v] { add_file $src }
add_file $ROOT/project/instrument_top.v
add_file $ROOT/constraint/instrument_mega138k.cst
add_file $ROOT/constraint/instrument_mega138k.sdc
set_option -top_module instrument_top
run syn
run pnr

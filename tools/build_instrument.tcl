# Separate live-instrument project; the verified fixed-tone project is untouched.
set ROOT {E:/GowinProjects/synth_top}
set DEVICE {GW5AST-LV138PG484AC1/I0}
set DEVVER {C}
cd $ROOT
create_project -name instrument_top -dir $ROOT/project -pn $DEVICE -device_version $DEVVER -force

add_file $ROOT/rtl/common/reset_sync.v
add_file $ROOT/rtl/system/clock_gen.v
add_file $ROOT/rtl/system/sample_scheduler.v
add_file $ROOT/rtl/system/i2s_tx_official.v
add_file $ROOT/rtl/system/system_status.v
foreach src [glob $ROOT/rtl/audio_core/*.v] { add_file $src }
foreach src [glob $ROOT/rtl/input/*.v] { add_file $src }
foreach src [glob $ROOT/rtl/ui/*.v] { add_file $src }
add_file $ROOT/project/instrument_top.v

add_file $ROOT/constraint/instrument_mega138k.cst
add_file $ROOT/constraint/instrument_mega138k.sdc
set_option -top_module instrument_top

puts "=== INSTRUMENT SYNTHESIS ==="
run syn
puts "=== INSTRUMENT PLACE AND ROUTE ==="
run pnr
puts "=== INSTRUMENT BUILD DONE ==="

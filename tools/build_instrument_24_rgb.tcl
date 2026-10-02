set ROOT [file dirname [file dirname [file normalize [info script]]]]
cd $ROOT
create_project -name instrument_24_rgb_top -dir $ROOT/project -pn GW5AST-LV138PG484AC1/I0 -device_version C -force
foreach src [glob $ROOT/rtl/audio_core/*.v] { add_file $src }
foreach src {reset_sync} { add_file $ROOT/rtl/common/$src.v }
foreach src {clock_gen sample_scheduler system_status i2s_tx_official} { add_file $ROOT/rtl/system/$src.v }
foreach src {matrix_scan_8x6 keyboard_24_dual keyboard_24_input} { add_file $ROOT/rtl/input/$src.v }
foreach src {rgb_lcd_800x480 lcd_status_bridge} { add_file $ROOT/rtl/ui/$src.v }
add_file $ROOT/project/instrument_24_rgb_top.v
add_file $ROOT/constraint/instrument_24_rgb_mega138k.cst
add_file $ROOT/constraint/instrument_24_rgb_mega138k.sdc
set_option -top_module instrument_24_rgb_top
run syn
run pnr
puts "=== 24-KEY RGB INSTRUMENT BUILD DONE ==="

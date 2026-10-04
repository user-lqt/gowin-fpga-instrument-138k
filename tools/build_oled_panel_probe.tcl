set ROOT {E:/GowinProjects/synth_top}
set DEVICE {GW5AST-LV138PG484AC1/I0}
set DEVVER {C}
cd $ROOT
create_project -name oled_panel_probe_top -dir $ROOT/project -pn $DEVICE -device_version $DEVVER -force
add_file $ROOT/rtl/common/reset_sync.v
add_file $ROOT/rtl/system/clock_gen.v
add_file $ROOT/rtl/ui/oled_content.v
add_file $ROOT/rtl/ui/oled_font.v
add_file $ROOT/rtl/ui/oled_i2c_master.v
add_file $ROOT/rtl/ui/oled_display.v
add_file $ROOT/project/oled_panel_probe_top.v
add_file $ROOT/constraint/oled_panel_probe_mega138k.cst
add_file $ROOT/constraint/oled_panel_probe_mega138k.sdc
set_option -top_module oled_panel_probe_top
puts "=== ISOLATED OLED PANEL SYNTHESIS ==="
run syn
puts "=== ISOLATED OLED PANEL PLACE AND ROUTE ==="
run pnr
puts "=== ISOLATED OLED PANEL BUILD DONE ==="

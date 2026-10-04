set ROOT {E:/GowinProjects/synth_top}
cd $ROOT
create_project -name oled_vendor_probe_top -dir $ROOT/project -pn GW5AST-LV138PG484AC1/I0 -device_version C -force
add_file $ROOT/rtl/common/reset_sync.v
add_file $ROOT/rtl/ui/oled_i2c_master.v
add_file $ROOT/rtl/ui/oled_vendor_probe.v
add_file $ROOT/project/oled_vendor_probe_top.v
add_file $ROOT/constraint/oled_panel_probe_mega138k.cst
add_file $ROOT/constraint/oled_vendor_probe_mega138k.sdc
set_option -top_module oled_vendor_probe_top
run syn
run pnr

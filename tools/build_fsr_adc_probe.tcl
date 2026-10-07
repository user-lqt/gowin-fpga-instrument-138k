# Small CH0-only hardware diagnostic, preserving every earlier build.
set ROOT [file dirname [file dirname [file normalize [info script]]]]
cd $ROOT
set BUILD_BASE_NAME fsr_adc_probe
set BUILD_NAME $BUILD_BASE_NAME
set BUILD_SUFFIX [clock format [clock seconds] -format %Y%m%d_%H%M%S]
set BUILD_ATTEMPT 0
while {[file exists $ROOT/project/$BUILD_NAME]} {
    incr BUILD_ATTEMPT
    set BUILD_NAME ${BUILD_BASE_NAME}_${BUILD_SUFFIX}_${BUILD_ATTEMPT}
}
puts "FSR_ADC_PROBE_PROJECT=$ROOT/project/$BUILD_NAME"
create_project -name $BUILD_NAME -dir $ROOT/project -pn GW5AST-LV138PG484AC1/I0 -device_version C -force
add_file $ROOT/rtl/system/clock_gen.v
add_file $ROOT/rtl/common/reset_sync.v
foreach src {mcp3008_spi mcp3008_sampler expression_mapper fsr_expression_control} {
    add_file $ROOT/rtl/input/$src.v
}
foreach src {lcd_status_bridge rgb_lcd_800x480} {
    add_file $ROOT/rtl/ui/$src.v
}
add_file $ROOT/project/fsr_adc_probe_top.v
add_file $ROOT/constraint/instrument_24_rgb_mega138k.cst
add_file $ROOT/constraint/fsr_adc_probe_mega138k.sdc
set_option -top_module fsr_adc_probe_top
run syn
run pnr
puts "=== CH0 ONLY ADC PROBE BUILD DONE ==="

# Build the measured-FSR instrument without adding guitar source files.
# Existing projects and generated outputs are preserved; this script uses a
# separate project directory for the no-guitar build.
set ROOT [file dirname [file dirname [file normalize [info script]]]]
cd $ROOT
set BUILD_NAME instrument_24_rgb_fsr_measured_noguitar
set BUILD_BASE_NAME $BUILD_NAME
set BUILD_SUFFIX [clock format [clock seconds] -format %Y%m%d_%H%M%S]
set BUILD_ATTEMPT 0
while {[file exists $ROOT/project/$BUILD_NAME]} {
    incr BUILD_ATTEMPT
    set BUILD_NAME ${BUILD_BASE_NAME}_${BUILD_SUFFIX}_${BUILD_ATTEMPT}
}
puts "FSR_NO_GUITAR_PROJECT=$ROOT/project/$BUILD_NAME"

create_project -name $BUILD_NAME -dir $ROOT/project -pn GW5AST-LV138PG484AC1/I0 -device_version C -force

# The top instantiates audio_core with ENABLE_GUITAR=0. Keep only the source
# modules required by the piano/bell implementation in this project file.
foreach src {
    adsr audio_core bianzhong bianzhong_ram_bank fm_operator mixer
    note_to_fc note_to_period oscillator phase_acc pitch_expression
    pitch_fraction_rom voice voice_allocator wavetable
} {
    add_file $ROOT/rtl/audio_core/$src.v
}
add_file $ROOT/rtl/common/reset_sync.v
foreach src {clock_gen sample_scheduler system_status i2s_tx_official audio_frame_buffer} {
    add_file $ROOT/rtl/system/$src.v
}
foreach src {
    matrix_scan_8x6 keyboard_24_dual keyboard_24_input encoder key_debounce
    encoder_control encoder_b_input encoder_b_control encoder_param_queue
    mcp3008_spi mcp3008_sampler joystick_control expression_mapper
    fsr_expression_control
} {
    add_file $ROOT/rtl/input/$src.v
}
add_file $ROOT/rtl/ui/parameter_manager.v
foreach src {rgb_lcd_800x480 lcd_status_bridge} {
    add_file $ROOT/rtl/ui/$src.v
}
add_file $ROOT/project/instrument_24_rgb_top.v
add_file $ROOT/constraint/instrument_24_rgb_mega138k.cst
add_file $ROOT/constraint/instrument_24_rgb_mega138k.sdc
set_option -top_module instrument_24_rgb_top
run syn
run pnr
puts "=== 24-KEY RGB FSR MEASURED NO-GUITAR BUILD DONE ==="

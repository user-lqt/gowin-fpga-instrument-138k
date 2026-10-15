# Build a separate piano/bell + FSR + joystick-X pitch-bend test bitstream.
# Keep the normal top's joystick default and all earlier projects untouched.
set ROOT [file dirname [file dirname [file normalize [info script]]]]
cd $ROOT
set BUILD_BASE_NAME instrument_24_rgb_joystick_bend_test
set BUILD_SUFFIX [clock format [clock seconds] -format %Y%m%d_%H%M%S]
set BUILD_NAME ${BUILD_BASE_NAME}_${BUILD_SUFFIX}
set BUILD_ATTEMPT 0
while {[file exists $ROOT/project/$BUILD_NAME]} {
    incr BUILD_ATTEMPT
    set BUILD_NAME ${BUILD_BASE_NAME}_${BUILD_SUFFIX}_${BUILD_ATTEMPT}
}

set top_in [open $ROOT/project/instrument_24_rgb_top.v r]
set top_source [read $top_in]
close $top_in
set replacements [regsub -all {parameter integer ENABLE_JOYSTICK = 0,} \
    $top_source {parameter integer ENABLE_JOYSTICK = 1,} test_top_source]
if {$replacements != 1} {
    error "Expected exactly one disabled joystick parameter in the normal top"
}

create_project -name $BUILD_NAME -dir $ROOT/project \
    -pn GW5AST-LV138PG484AC1/I0 -device_version C
set generated_dir $ROOT/project/$BUILD_NAME/generated
file mkdir $generated_dir
set top_out [open $generated_dir/instrument_24_rgb_top.v w]
fconfigure $top_out -encoding utf-8 -translation lf
puts -nonewline $top_out $test_top_source
close $top_out
puts "JOYSTICK_TEST_PROJECT=$ROOT/project/$BUILD_NAME"
puts "JOYSTICK_TEST_CONFIG=ENABLE_JOYSTICK=1; piano/bell; 32 voices; FSR CH0; X CH1; Y CH2 sampled only"

# Guitar modules are deliberately excluded from the two-timbre project.
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
add_file $generated_dir/instrument_24_rgb_top.v
add_file $ROOT/constraint/instrument_24_rgb_mega138k.cst
add_file $ROOT/constraint/instrument_24_rgb_mega138k.sdc
set_option -top_module instrument_24_rgb_top
run syn
run pnr
puts "JOYSTICK_TEST_BITSTREAM=$ROOT/project/$BUILD_NAME/impl/pnr/$BUILD_NAME.fs"
puts "=== JOYSTICK PITCH-BEND TEST BUILD DONE ==="

set ROOT [file dirname [file dirname [file normalize [info script]]]]
cd $ROOT
create_project -name instrument_fixed_top -dir $ROOT/project -pn GW5AST-LV138PG484AC1/I0 -device_version C -force
foreach src [glob $ROOT/rtl/audio_core/*.v] { add_file $src }
foreach src {matrix_scan_8x6 keyboard_24_dual keyboard_24_input encoder key_debounce encoder_control encoder_b_input encoder_b_control encoder_param_queue ble_uart_rx k230_control_rx instrument_link performance_event_merge} { add_file $ROOT/rtl/input/$src.v }
foreach src {mcp3008_spi mcp3008_sampler expression_mapper fsr_expression_control joystick_control} { add_file $ROOT/rtl/input/$src.v }
foreach src {parameter_manager rgb_lcd_800x480 lcd_status_bridge waveform_buffer instrument_dashboard audio_visualizer strike_display_formatter} { add_file $ROOT/rtl/ui/$src.v }
foreach src {clock_gen sample_scheduler system_status i2s_tx_pcm5102a lesson_guide audio_delay_fx polyphony_test keyboard_led_strip} { add_file $ROOT/rtl/system/$src.v }
add_file $ROOT/rtl/common/reset_sync.v
add_file $ROOT/project/instrument_24_rgb_top.v
add_file $ROOT/constraint/instrument_24_rgb_mega138k.cst
add_file $ROOT/constraint/instrument_24_rgb_mega138k.sdc
set_option -top_module instrument_24_rgb_top
run syn
if {[lsearch -exact $argv "syn_only"] < 0} { run pnr }
puts "=== VELOCITY 32 BUILD DONE ==="

set ROOT [file dirname [file dirname [file normalize [info script]]]]
cd $ROOT
set variant [lindex $argv 0]
    create_project -name $variant -dir $ROOT/diagnostics/projects -pn GW5AST-LV138PG484AC1/I0 -device_version C -force
    if {$variant == "lcd_only"} {
        add_file $ROOT/rtl/ui/rgb_lcd_800x480.v
        set_option -top_module rgb_lcd_800x480
    } else {
        if {$variant == "a_baseline"} {
            set sources $ROOT/diagnostics/a_baseline/rtl/audio_core
        } else {
            set sources $ROOT/diagnostics/velocity_before/audio_core
        }
        foreach src [glob $sources/*.v] { add_file $src }
        set_option -top_module audio_core
    }
    run syn
    puts "RESOURCE COMPARISON COMPLETED: $variant"

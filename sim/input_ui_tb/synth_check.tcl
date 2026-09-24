# Run with gw_sh.exe from a dedicated results directory, not the user's project.
# First optional argument selects input_top or oled_content.
set root [file normalize [file join [file dirname [info script]] ../..]]
set top input_top
if {[llength $argv] > 0} { set top [lindex $argv 0] }
if {$top ni {input_top oled_content}} { error "Unsupported synthesis top" }
set_device -name GW5AST-138C GW5AST-LV138PG484AC1/I0
foreach source [glob [file join $root rtl/input/*.v] [file join $root rtl/ui/*.v]] {
    if {[file size $source] > 0} { add_file $source }
}
set_option -top_module $top
set_option -output_base_name $top
set_option -verilog_std v2001
run syn

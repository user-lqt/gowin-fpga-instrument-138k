set ROOT [file dirname [file normalize [info script]]]
cd $ROOT
source $ROOT/keyboard_build_guard.tcl
open_project $ROOT/integrated_instrument_64.gprj
set_option -top_module instrument_64_top
set_option -output_base_name integrated_instrument_64
set_option -include_path {source/rtl/common;source/rtl/input;source/rtl/ui/new_screen}
set_option -place_option 3
set_option -route_option 0
set_option -oreg_in_iob 1
set_option -replicate_resources 1
set_option -clock_route_order 1
set_option -route_maxfan 23
set_option -convert_sdp32_36_to_sdp16_18 0
set_option -inc_place 0
if {[llength $argv] != 1} { error "Specify one stage: syn or pnr" }
set phase [lindex $argv 0]
if {$phase eq "syn"} {
    run syn
} elseif {$phase eq "pnr"} {
    run pnr
    source $ROOT/check_physical_result.tcl
    require_routed_bitstream $ROOT/impl integrated_instrument_64
} else {
    error "Unknown build stage"
}
puts "BUILD STAGE COMPLETE $phase"

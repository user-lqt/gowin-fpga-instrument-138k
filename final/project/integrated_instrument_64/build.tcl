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
run syn
if {[lsearch -exact $argv pnr]>=0} {
 run pnr
 source $ROOT/check_physical_result.tcl
 require_routed_bitstream $ROOT/impl integrated_instrument_64
}
puts "DELIVERY BUILD COMPLETE integrated_instrument_64"

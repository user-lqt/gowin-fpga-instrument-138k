# Keep every previous project and bitstream. Each retry gets a fresh project.
set ROOT [file dirname [file dirname [file normalize [info script]]]]
if {![info exists BUILD_NAME]} {set BUILD_NAME instrument_24_rgb_fsr_vibrato}
set BUILD_BASE_NAME $BUILD_NAME
set BUILD_SUFFIX [clock format [clock seconds] -format %Y%m%d_%H%M%S]
set BUILD_ATTEMPT 0
while {[file exists $ROOT/project/$BUILD_NAME]} {
    incr BUILD_ATTEMPT
    set BUILD_NAME ${BUILD_BASE_NAME}_${BUILD_SUFFIX}_${BUILD_ATTEMPT}
}
source $ROOT/tools/build_instrument_24_rgb.tcl
puts "FSR_VIBRATO_PROJECT=$ROOT/project/$BUILD_NAME"

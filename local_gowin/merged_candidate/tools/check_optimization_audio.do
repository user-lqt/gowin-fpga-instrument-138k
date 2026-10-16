onerror {quit -code 1 -force}
set ROOT [pwd]
set LIB $ROOT/sim/optimization_modelsim
if {![file exists $LIB]} {vlib $LIB}
if {[info exists env(OPT_BASELINE)]} {
    set SOURCES $ROOT/../../tmp/resource_optimization/baseline_rtl/audio_core
} else {
    set SOURCES $ROOT/rtl/audio_core
}
foreach source [glob $SOURCES/*.v] {
    vlog -sv -work $LIB +incdir+$ROOT/rtl/common $source
}
vlog -sv -work $LIB +incdir+$ROOT/rtl/common $ROOT/sim/audio_core_tb/tb_optimization_audio.v
vsim -t 1ps -lib $LIB tb_optimization_audio
run -all
quit -code 0 -force

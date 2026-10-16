onerror {quit -code 1 -force}
set ROOT [pwd]
set LIB $ROOT/sim/merged_audio_modelsim
if {![file exists $LIB]} {vlib $LIB}
foreach source [glob $ROOT/rtl/audio_core/*.v] {
    vlog -sv -work $LIB +incdir+$ROOT/rtl/common $source
}
vlog -sv -work $LIB +incdir+$ROOT/rtl/common $ROOT/sim/audio_core_tb/tb_merged_audio.v
vsim -t 1ps -lib $LIB tb_merged_audio
run -all
quit -code 0 -force

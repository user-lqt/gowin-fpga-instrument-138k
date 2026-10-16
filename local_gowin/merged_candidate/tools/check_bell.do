onerror {quit -code 1 -force}
set ROOT [pwd]
set LIB $ROOT/sim/bell_modelsim
if {![file exists $LIB]} {vlib $LIB}
foreach source [glob $ROOT/rtl/audio_core/*.v] {
    vlog -sv -work $LIB +incdir+$ROOT/rtl/common $source
}
vlog -sv -work $LIB $ROOT/sim/audio_core_tb/tb_bell_envelope.v
vlog -sv -work $LIB $ROOT/sim/audio_core_tb/tb_bell_audition.v
cd $ROOT/sim/merged_checks
vsim -t 1ps -lib $LIB tb_bell_audition
run -all
quit -code 0 -force

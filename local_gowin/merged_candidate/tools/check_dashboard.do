onerror {quit -code 1 -force}
set ROOT [pwd]
set LIB $ROOT/sim/merged_modelsim
if {![file exists $LIB]} {vlib $LIB}
vlog -sv -work $LIB $ROOT/rtl/ui/instrument_dashboard.v
vlog -sv -work $LIB $ROOT/sim/audio_core_tb/tb_dashboard_preview.v
cd $ROOT/sim/merged_checks
vsim -t 1ps -lib $LIB tb_dashboard_preview
run -all
quit -code 0 -force

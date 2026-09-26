# In Questa Transcript: do C:/.../sim/audio_core_tb/questa.do
# Optional target: do C:/.../sim/audio_core_tb/questa.do tb_audio_core
set script_dir [file dirname [file normalize [info script]]]
set repo [file normalize [file join $script_dir ../..]]
set target tb_adsr
if {[info exists 1]} { set target [set 1] }
if {$target ni {tb_audio_core tb_audio_core_a2 tb_adsr tb_mixer tb_voice_allocator tb_voice}} {
    error "Unknown testbench: $target"
}
set build [file join $script_dir build questa]
file mkdir $build
file mkdir [file join $build waveforms]
cd $build
if {![file isdirectory work]} { vlib work }
vmap work [file join $build work]
set sources [glob [file join $repo rtl audio_core *.v]]
vlog -sv +incdir+$repo/rtl/common {*}$sources [file join $script_dir $target.v]
vsim -voptargs=+acc work.$target
add wave -r sim:/$target/*
run -all

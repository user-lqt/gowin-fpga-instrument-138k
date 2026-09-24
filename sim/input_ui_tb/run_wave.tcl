log_wave -r /*
open_vcd waveform.vcd
log_vcd [get_objects -r /*]
run all
close_vcd
quit

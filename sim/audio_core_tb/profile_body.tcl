set HERE [file dirname [file normalize [info script]]]
set ROOT [file normalize $HERE/../..]
foreach TOP {guitar_body_tone_bank guitar_body_ram_bank} {
    create_project -name $TOP -dir $HERE/build/gowin_body \
        -pn GW5AST-LV138PG484AC1/I0 -device_version C -force
    add_file $ROOT/rtl/audio_core/$TOP.v
    set_option -top_module $TOP
    run syn
}

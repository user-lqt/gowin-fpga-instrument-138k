# Fail closed if a regenerated package restores the superseded press debounce.
set keyboard_source [file join $ROOT source project instrument_24_rgb_top.v]
set keyboard_stream [open $keyboard_source r]
set keyboard_text [read $keyboard_stream]
close $keyboard_stream
foreach {name expected} {ROW_CYCLES 307 DEBOUNCE_FRAMES 15} {
    set pattern [format {parameter\s+integer\s+%s\s*=\s*([0-9]+)} $name]
    if {![regexp $pattern $keyboard_text match actual] || $actual != $expected} {
        error "KEYBOARD CONFIG: expected $name=$expected in $keyboard_source"
    }
}
if {![regexp {\.RELEASE_DEBOUNCE_FRAMES\(64\)} $keyboard_text]} {
    error "KEYBOARD CONFIG: release debounce must remain64"
}
puts "KEYBOARD CONFIG GUARD: press15 release64 row307"

# Gowin may return from "run pnr" after PR0004 without a Tcl error.
set physical_guard_tools [file dirname [file normalize [info script]]]
proc require_routed_bitstream {impl basename} {
    set report [file join $impl pnr ${basename}.rpt.txt]
    set image [file join $impl pnr ${basename}.fs]
    set netlist [file join $impl gwsynthesis ${basename}.vg]
    set project [file join [file dirname $impl] ${basename}.gprj]
    set stream [open $project r]
    set project_text [read $stream]
    close $stream
    foreach {entry relative} [regexp -all -inline {<File path="([^"]+)"} $project_text] {
        set dependency [file normalize [file join [file dirname $project] $relative]]
        if {[file mtime $dependency] > [file mtime $netlist]} {
            error "STALE NETLIST: source is newer than synthesis: $dependency"
        }
    }
    if {![file exists $report]} {error "Physical report was not generated: $report"}
    if {[file mtime $report] < [file mtime $netlist]} {
        error "Physical report predates the input netlist: $report"
    }
    set stream [open $report r]
    set text [read $stream]
    close $stream
    if {[regexp -nocase {total[ \t]+([0-9]+)[ \t]+unrouted nets} $text match count]} {
        if {$count != 0} {error "ROUTING FAILED: $count unrouted nets; no usable new bitstream"}
    }
    if {[regexp {ERROR[ \t]*\(} $text]} {error "Physical report contains an error: $report"}
    if {![file exists $image]} {error "No bitstream was generated: $image"}
    if {[file mtime $image] < [file mtime $netlist]} {
        error "Bitstream predates the input netlist: $image"
    }
    set timing [file join $impl pnr ${basename}_tr_content.html]
    if {![file exists $timing]} {error "Timing report was not generated: $timing"}
    if {[file mtime $timing] < [file mtime $netlist]} {
        error "Timing report predates the input netlist: $timing"
    }
    set stream [open $timing r]
    set timing_text [read $stream]
    close $stream
    require_timing_closure $timing_text
    # The legacy audio-only warning allowlist does not classify the new FFT.
    # Preserve full synthesis/route logs; do not suppress third-party warnings.
    puts "ROUTED BITSTREAM: $image; setup/hold endpoints verified zero; board I/O budgets still require validation"
}

proc require_timing_closure {text} {
    foreach kind {Setup Hold} {
        set pattern [format {Numbers of %s Violated Endpoints</td>\s*<td>([0-9]+)</td>} $kind]
        if {![regexp $pattern $text match count]} {
            error "TIMING FAILED: missing $kind violated endpoint count"
        }
        if {$count != 0} {error "TIMING FAILED: $count $kind violated endpoints"}
    }
    if {![regexp {Numbers of Paths Analyzed</td>\s*<td>([0-9]+)</td>} $text match paths] ||
        $paths == 0} {
        error "TIMING FAILED: no paths analyzed"
    }
}

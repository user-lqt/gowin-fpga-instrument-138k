# Dual-contact strike expression

## Current mode: fast strike raises pitch

The latest requested mode supersedes the amplitude/harmonic behavior described
below. A-to-B travel under 1 second keeps the original pitch at gain 127.
Travel of about 1 second or longer selects SLOW: the sounding pitch drops by
one octave (12 semitones) and gain becomes 51, approximately 40% amplitude.
The allocator retains the original note ID so NOTE_OFF still matches correctly.
The downward octave saturates at MIDI 0. The threshold requires physical
calibration; two closures within the same scan frame always select FAST.
The test checks the 5003/5004-frame boundary, output frequency and energy.
The hardware top uses AB_MAX_FRAMES=5004: through 5003 scan frames (~1 s)
is FAST; longer is SLOW (velocity 16). This is the contact closure interval,
not how long the user holds a key.

## Previous revisions


The decoder captures first raw A and B closures, then requires both contacts
to pass debounce before sending NOTE_ON. A raw bounce does not restart travel
timing. A full qualified release rearms the key. Timing resolution remains one
8-row scan frame (about 0.2 ms with the new hardware defaults); changes
within the same scan frame cannot be distinguished.

Velocity uses a monotonic seven-level travel curve. With the hardware top,
intervals up to about 0.2, 0.4, 1, 2, 4 and 8 ms map to 127, 112, 92, 68, 44
and 28; longer intervals map to 16. Gain is velocity squared / 128, with a
minimum of 12 for nonzero strikes. Harmonic weighting rises from zero to
one half; this increases both loudness and brightness contrast. The audible minimum prevents very slow keys
from appearing dead. Voice latches velocity on NOTE_ON, applies amplitude
scaling and blends in a phase-coherent second harmonic according to velocity.
The fundamental pitch is unchanged. This is an expressive synthesized tone,
not a sampled acoustic piano. The current four-voice limit is unchanged.

Run tools/verify_strike_expression.ps1 with the local Vivado 2022.2 simulator.
Tests cover dual-contact fast/slow strikes, bounce, 24-key serialization,
release, and compare audio energy and second-harmonic content. Build using
tools/build_instrument_24_rgb.tcl so the generated project references this liu
folder, rather than the previous E:/GowinProjects/synth_top paths.

Physical A must close before B and remain closed until B is pressed. Each
contact has its own diode; shorting A and B together always measures a fast
strike. Scan-frame quantization and first-contact bounce require mechanical
calibration on the actual conductive-rubber keyboard.

Validation on 2026-10-03: Vivado XSim passes the dual-contact, expressive
voice and scan-to-DAC integration tests. The expressive audio test compares
velocities 127 and 24 with the same pitch and constant envelope; the hard strike contains a measurable second
harmonic while the soft sine strike has none. Board listening/calibration is
still required. Gowin retains the existing PR1014 reference-clock routing
warning; successful builds do not constitute a board listening test.

The increased-sensitivity revision passes all three tests. At velocities 127
and 24, measured energy ratio is 55.125 (RMS amplitude ratio 7.425, about
17.4 dB), compared with the preceding revision's RMS ratio of about 3.82.
Intervals within one 0.2 ms frame still cannot be distinguished; intervals
above 8 ms saturate at the softest setting. These are provisional mechanical
calibration points, not measured properties of the physical keyboard.

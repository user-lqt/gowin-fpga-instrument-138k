# B velocity integration

Source: GitHub origin/dev-audio commit 6035c11. Audio scheduling and
32-voice allocation are retained. The system top comes from undone;
keyboard, controls, RGB and constraints come from the existing liu project.
This directory is an independent local integration, not a GitHub push.

## Keyboard

K1..K24 A-to-B thresholds (milliseconds):
10,18,6,5,20,20,20,20,1,10,3,1,1,30,20,20,10,1,10,3,18,1,30,30.
At ROW_CYCLES=307 and 12.288 MHz the full scan is approximately 0.2 ms.
Below the boundary sends velocity 127; at/above sends velocity 16.
Press debounce remains 40 scans and release debounce 64 scans.
These are two strike classes, not a continuous measurement of force.

## Sound

For ENABLE_TIMBRES=1: velocities 1..32 use gain 89/127 (70.1%),
33..90 use 108/127 (85.0%), 91..127 use full gain. Zero is silent.
This is output amplitude gain, not a guarantee of 70% perceived loudness:
spectra and attack envelopes also change the measured acoustic energy.
The legacy A1/A2 path retains its original linear gain.
The integrated top scales EC11 master-volume payloads by 1/16, mapping
the UI midpoint to approximately 0x0800 and full scale to 0x0fff;
this preserves headroom rather than replacing A's 0x07ff default with 0x8102.

Piano: soft/transient-low brightness reduces fundamental weight 12.5%,
increases second partial 25%, and halves third/fifth weights. Existing
velocity brightness still controls upper-partial transient energy.
Guitar: soft excitation halves the noise contribution and pick transient;
the baseline velocity-dependent feedback filter is retained.
Bell: soft strikes retain the first two modes, use 87.5% for mode 2,
50% for modes 3/4, and 25% for modes 5..7. Medium strikes use 75% for
modes 3..7. Hard strikes retain full modal levels. Mode frequencies do not change.

Attack durations at 48 kHz (soft / medium / hard):
piano 20 / 5 / 2.5 ms; guitar and bell 8 / 2 / 1 ms.
No slow-strike octave transposition: all classes retain the original note,
in accordance with A's new audio integration contract.

Audio changes: voice.v, adsr.v, oscillator.v, plucked_string.v,
bianzhong.v, bianzhong_ram_bank.v, audio_core.v (bell velocity connection).
Added ports: adsr.velocity, bianzhong.velocity, bianzhong_ram_bank.velocities.
A's 64-voice migration must carry these connections and cached bell velocity;
the 64-voice implementation has not been changed or verified here.

## Reproduction

From this directory:
`powershell -ExecutionPolicy Bypass -File tools/verify_velocity.ps1`
uses the installed XSim and captures PCM under sim/audio_core_tb/build/xsim.
`E:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe tools/build_velocity.tcl`
builds project/instrument_velocity_32.

The original A regression scripts and development README are retained.
The XSim suite separately checks three strike levels at a fixed note,
gain/attack/soft-piano weights, 32 simultaneous voices in all three timbres,
109-clock output latency, 256-clock cadence, release, all 24 threshold
boundaries, debounce and event serialization. Board listening is still required.

## Verification results (2026-10-07)

XSim: tb_velocity_response PASS (1197 output frames),
tb_velocity_cadence PASS (3846 output frames), and
tb_keyboard_24_dual PASS (all 24 timing boundaries and burst events).
This is focused integration coverage, not A's complete original regression.

Gowin V1.9.12 synthesis completed. Reported logic usage is
118377 / 138240 (85.6%). Width-truncation and clock-relationship warnings
remain; this is not a warning-free build.
Placement completed; routing was manually stopped after the complete build
had run for over 30 minutes without a new routing phase result.
No new bitstream or final timing result is available. Open the generated
project/instrument_velocity_32/instrument_velocity_32.gprj and run
Place & Route before programming. Do not use any old bitstream as proof
that these velocity changes have been built.

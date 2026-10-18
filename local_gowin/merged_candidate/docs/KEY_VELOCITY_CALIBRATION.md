# Key Velocity Calibration Display

The local merged candidate displays the most recent raw A-to-B measurement:

- `AB 0010.0 MS`: measured travel interval, rounded to 0.1 ms.
- `K 01 V 088`: measured key (01..24) and the velocity selected by the decoder.
- Dashes indicate that no measurement has occurred since reset.
- Releasing the key does not erase the measurement.

Time is calculated from complete scan frames using eight rows, the top-level
`ROW_CYCLES`, and a nominal 12.288 MHz audio clock. With `ROW_CYCLES=307`,
one frame is approximately 0.19987 ms. The decimal display does not imply
0.1 ms measurement resolution. Same-frame A/B closures display 0.0 ms.

This is the raw travel measurement, not proof of a debounced NOTE_ON. The
current calibration uses the supplied five light/medium/heavy trials per key.
Each key has four scan-frame breakpoints based on its three sample medians:
hard median, hard/medium midpoint, medium median, and medium/soft midpoint.
As travel time increases, these select velocity values 127, 108, 88, 68, and
48. This five-level curve is a resource-conscious approximation, not
continuous force measurement, and gives soft strikes a floor above the
previous velocity 16.

| Key | Hard | Hard/medium | Medium | Medium/soft |
|---|---:|---:|---:|---:|
| K01 | 4 | 16 | 28 | 128 |
| K02 | 9 | 69 | 130 | 301 |
| K03 | 4 | 10 | 16 | 36 |
| K04 | 4 | 12 | 20 | 38 |
| K05 | 12 | 75 | 139 | 239 |
| K06 | 19 | 52 | 84 | 381 |
| K07 | 27 | 79 | 132 | 256 |
| K08 | 25 | 74 | 124 | 256 |
| K09 | 4 | 8 | 12 | 19 |
| K10 | 6 | 29 | 53 | 201 |
| K11 | 3 | 9 | 16 | 147 |
| K12 | 3 | 6 | 10 | 59 |
| K13 | 17 | 71 | 125 | 445 |
| K14 | 10 | 67 | 124 | 731 |
| K15 | 11 | 52 | 93 | 239 |
| K16 | 15 | 49 | 84 | 172 |
| K17 | 8 | 32 | 57 | 116 |
| K18 | 1 | 3 | 6 | 59 |
| K19 | 9 | 24 | 40 | 120 |
| K20 | 6 | 11 | 17 | 47 |
| K21 | 13 | 62 | 112 | 251 |
| K22 | 2 | 3 | 5 | 12 |
| K23 | 48 | 99 | 151 | 426 |
| K24 | 26 | 59 | 93 | 222 |

K06 now uses its own measured light/medium/hard medians: 135.3/16.8/3.8 ms.
K13 replaces its former near-zero measurements with 152.9/25.0/3.4 ms.
Both keys now have five distinct velocity levels; K06 no longer copies K05.
Re-check after firmware changes or any keyboard mechanics adjustment.
Very slow/incomplete travel saturates at the existing frame-count limit.

## Guitar Dynamics

The guitar reuses the scheduled voice gain multiplier. At decoder velocities
48/88/127, its gain coefficients are now 60/128/206 instead of 48/88/127.
This raises the guitar level while expanding the soft-to-hard gain ratio.
The string excitation also reduces broadband pick energy more on soft plucks.
Neither string period nor feedback tuning is changed by this adjustment.
Piano and bell gain curves remain unchanged.

`tb_guitar_dynamics` checks gain monotonicity and bounds, then renders MIDI
48/60/72 at all three velocities through the shared production arithmetic.
It checks finite stereo PCM, increasing mean absolute amplitude and overflow
flags. These short single-note tests do not prove subjective realism,
frequency accuracy, or clipping headroom under maximum polyphony.

The temporary display occupies text row 25 (y=400..415), below the lesson/rhythm
status and above the physical key tiles. It does not replace recording, spectrum,
XY, or phone features. It appears on the performance page only.
Time formatting uses one accumulation clock per measured scan frame, followed
by sixteen shift/add-3 decimal-conversion clocks. The scale constants are
evaluated at elaboration: there is no runtime multiply or divide in this
formatter. The result is published atomically. At the current 5004-frame
measurement limit formatting takes approximately 0.41 ms at 12.288 MHz.
The existing status bridge transfers the snapshot to the pixel domain.

Validation: Icarus `tb_strike_formatter` checks reset placeholders, key numbering,
velocity formatting, release retention, and 0.0, 0.2, 10.0, 30.0 and 1000.1 ms.
`tb_merged_dashboard` checks the character positions and decimal conversion.
These tests feed captured measurements; they do not validate physical contacts,
PLL timing, or final place-and-route.

Re-run synthesis and place-and-route before programming. Existing prebuilt
bitstreams do not include this display change.

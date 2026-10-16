# Key Velocity Calibration Display

The local merged candidate displays the most recent raw A-to-B measurement:

- `AB 0010.0 MS`: measured travel interval, rounded to 0.1 ms.
- `K 01 V 127`: measured key (01..24) and the existing binary velocity (016/127).
- Dashes indicate that no measurement has occurred since reset.
- Releasing the key does not erase the measurement.

Time is calculated from complete scan frames using eight rows, the top-level
`ROW_CYCLES`, and a nominal 12.288 MHz audio clock. With `ROW_CYCLES=307`,
one frame is approximately 0.19987 ms. The decimal display does not imply
0.1 ms measurement resolution. Same-frame A/B closures display 0.0 ms.

This is the raw travel measurement, not proof of a debounced NOTE_ON.
Test one key at a time. For each key, record about ten light, medium and
heavy strikes. The existing per-key thresholds and 16/127 mapping are unchanged.
Very slow/incomplete travel saturates at the existing frame-count limit.

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

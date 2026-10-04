# 24-key dual-contact keyboard: Tang Mega 138K 31005 wiring

Use the 31005 dock J13 header, 8 scan rows and 6 sensed columns. The 24 keys
are ordered left to right. For key number `n` (1..24), column is `(n-1)%6`;
its A row is `2*((n-1)/6)` and B row is A+1. Thus K1..K6 use R0/R1,
K7..K12 use R2/R3, K13..K18 use R4/R5, K19..K24 use R6/R7.

| Signal | J13 pin | FPGA ball |
| --- | ---: | --- |
| R0 `row_out[0]` | 1 | E14 |
| R1 `row_out[1]` | 2 | E13 |
| R2 `row_out[2]` | 3 | C15 |
| R3 `row_out[3]` | 4 | C14 |
| R4 `row_out[4]` | 5 | B13 |
| R5 `row_out[5]` | 6 | C13 |
| R6 `row_out[6]` | 7 | A14 |
| R7 `row_out[7]` | 8 | A13 |
| C0 `col_in[0]` | 9 | B16 |
| C1 `col_in[1]` | 10 | B15 |
| C2 `col_in[2]` | 13 | A16 |
| C3 `col_in[3]` | 14 | A15 |
| C4 `col_in[4]` | 15 | A20 |
| C5 `col_in[5]` | 16 | B20 |

J13-11 is **5 V**, not GPIO or a pull-up source. J13-12 is GND. Each column
needs its own 10 kOhm pull-up to a verified **3.3 V** source (external regulated
3.3 V if the dock does not expose one); all FPGA GPIO must remain at 3.3 V or
below. Never connect the 5 V header pin to a column.

EC11 diagnostic migration (2026-10-04): unused J13-17/A21, J13-18/B21,
J13-19/B18 now carry encoder A, B and switch D. See `EC11_DIAGNOSTIC.md`.
Do not reuse any of the 14 keyboard row/column GPIOs for the encoder.

Each of the 48 switches has its own 1N4148: column -> switch -> diode anode;
diode cathode (striped end) -> row bus. Each row has six such cathodes. Each
column joins eight switch contacts, one per row. A closed switch is sensed low
when its row is selected. Rows not selected are high impedance.

The new `keyboard_24_input` wrapper is separate from the legacy 4x4 `input_top`.
Integrators must instantiate the new wrapper, add its three source files, and
merge `constraint/keyboard_24_j13.cst` into the active top-level CST after
removing any obsolete EC11/OLED assignments to these same balls. This pinout
does not reserve GPIO for OLED or EC11. `ROW_CYCLES` must be set to obtain an
appropriate scan rate from the actual keyboard clock; defaults to 5000 cycles
per row. A/B timing and debounce are measured in complete 8-row frames.

The local integrated project is now `instrument_24_rgb_top`; its CST combines
this mapping with the onboard DAC and RGB display mapping. In that project,
rows use 1229 audio clocks (about 100 us/row), two-frame debounce, and NOTE
events are spaced by at least 256 audio clocks. MIDI notes are 48..71.
Legacy EC11 and OLED wiring must be disconnected from J13 before using this
mapping: their former pins now carry keyboard columns. See
`INSTRUMENT_24_RGB_INTEGRATION.md` for the build and validation record.

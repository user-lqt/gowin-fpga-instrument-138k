# EC11 input diagnostic

Current build: `gw_sh.exe tools/build_ec11_j13.tcl`

This build retains audio, keyboard and original volume/page behavior, but moves
EC11 from PMOD1 Bank4 to the unused J13 Bank2 GPIOs. Simulation cannot prove
physical pad operation. Earlier PMOD1 bitstreams and drawings are obsolete for
this wiring. No keyboard/LCD/audio pin assignments are changed.

Pins verified against 31005 Dock Rev1.3 schematic sheets 7 and 19:

| EC11 terminal | J13 position | FPGA ball | Dock net |
| --- | --- | --- | --- |
| A | 17 | A21 | SDRAM0_D9 |
| B | 18 | B21 | SDRAM0_D8 |
| D (switch) | 19 | B18 | SDRAM0_A12 |
| C and E | 12 or other verified GND | GND | GND |

Each of A/B/D has its own 4.7k pull-up: 3.3 V -> resistor -> signal node.
That signal node joins the corresponding EC11 terminal and FPGA input.
The three signal nodes must not be joined. Keep the existing verified 3.3 V
source (PMOD 3V3 can still supply the resistors); do not use J13-11 (5 V).
Disconnect the three old PMOD signal wires before moving them to J13.

Display additions (positions in the 800x480 active image):

| Position | Meaning |
| --- | --- |
| Upper right, four boxes left to right | A, B, switch, decoder ready |
| Green box | Logic 1 (switch released), or decoder ready |
| Red box | Logic 0 (switch pressed), or decoder not ready |
| Orange bar below volume bar | Synchronized A/B transition count |
| Cyan bar below orange bar | Decoded increment count |
| Pink bar below cyan bar | Decoded decrement count |
| Blue box to right of volume bar | Dim=volume page, bright=instrument page |

Counters start at zero after reset, grow by 2 pixels per count, and wrap at 256.
Quick transitions may not be visible in the A/B boxes at screen refresh rate;
the orange counter retains evidence of them. Turn slowly to observe the boxes.

Interpretation:

- Orange unchanged: no observed A/B transitions at the FPGA input path.
- Orange grows but cyan/pink do not: decoder/filter/phase sequence issue.
- Cyan/pink grow but volume unchanged: check page (rotation on instrument page does not change volume).
- Volume changes but sound does not: investigate the downstream audio path.

The diagnostic test drives CW/CCW phases through the real 2500-clock filter,
checks counters and audio volume, switch/page, cross-clock snapshot and actual
RGB output colors. Only switch debounce is shortened in simulation.

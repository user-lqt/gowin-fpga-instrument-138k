# LED strip bring-up

Active project: `project/instrument_velocity_32_two_timbres/instrument_velocity_32_two_timbres.gprj`.

SONG mode now starts automatically when EC11_B enters menu 2. Only the
current target lights green (brightness 32/255). Pressing the correct physical
key advances one note; wrong keys still play audio but do not advance.
Release and press again for repeated notes. Held keys on entry do not count.
Leaving SONG sends black to all 49 pixels; returning restarts at note one.
Rotation selects song 1/2 and restarts it. Long press restarts the current
score. Completing the score extinguishes the lights. Audio is still generated
by the ordinary keyboard path, not by the score.

Song 1 is the opening two phrases of Twinkle Little Star (14 notes):

`C4 C4 G4 G4 A4 A4 G4 | F4 F4 E4 E4 D4 D4 C4`

Physical key order:

`K1 K1 K8 K8 K10 K10 K8 | K6 K6 K5 K5 K3 K3 K1`

These are the nominal MIDI notes with BASE_NOTE=60; existing audio pitch
controls still apply. Tempo does not automatically advance this practice mode.
The RGB display shows the target key and current step /14 (song 2 remains /16).

K1..K24 map to one-based LED numbers:

`2,4,6,8,10,12,14,16,18,20,22,24,27,29,31,33,35,37,39,41,43,45,47,49`.

All other pixels in the first 49 are explicitly black. Count from the DIN end.
If the strip has more than 49 LEDs, set `LED_COUNT` in the driver instance to
the actual count to explicitly clear every trailing pixel as well.

## Wiring

- FPGA J13 pad marked **B17** (J13-20 on 31005 Rev1.3): 330 ohm series resistor,
  then strip **DIN**, not DOUT. CST signal: `led_strip_din`.
- Strip VDD: regulated **5 V** supply, not FPGA 3.3 V.
- Strip GND: supply negative and FPGA GND, common ground.
- Do not infer connector polarity from wire color. Read pad markings.
- Never connect 5 V or the strip DOUT to an FPGA signal input.
- Avoid live plugging; keep the initial data cable short.
- A 470 uF or larger capacitor across strip power is recommended.

The supplied 0807Z2RGB-5V-I4-H22 specification lists VIH=1.7 V, so a 3.3 V
data output meets its documented input threshold. Its page-12 drawing says
12 V, contradicting the device's 3.0..6.5 V rating: **use 5 V, never 12 V**.

Driver clock is audio PLL 725 MHz / 59. Bit period 15 clocks (~1.221 us),
zero high 4 clocks (~0.326 us), one high 9 clocks (~0.732 us), reset low
at least 1500 clocks (~122 us). Format is GRB, MSB first. A frame snapshots
the mask so pressing keys during transmission cannot corrupt it; the next
frame reflects changes (under 3.2 ms protocol delay for 49 pixels, excluding
keyboard debounce).

## Verification

`tb_keyboard_led_strip` decodes the serial output and checks all 49 pixel
words, all 24 key mappings, mode-exit blackout, re-entry, reset, high
pulse widths, bit period and reset-low time. `tb_lesson_guide` checks the score
order, correct/wrong/held/repeated keys, completion and mode restart. Integrated in
`tools/verify_velocity.ps1`. Physical strip operation remains to be checked
on the board. Do synthesis and place/route before downloading a new FS.

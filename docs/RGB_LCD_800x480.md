# 800x480 RGB666 display

`rtl/ui/rgb_lcd_800x480.v` is the first integrated instrument display. It
draws 24 key areas, highlights pressed keys, shows a volume bar and marks the
selected instrument. It is intentionally independent of the audio and input
top levels: instantiate it in the system top and connect synchronized
`key_state[23:0]`, `volume_value` and `instrument_value`.

The RGB666 pins are the official Sipeed example mapping: `sc_clk=L19`,
`sc_hs=N20`, `sc_vs=L15`, `sc_de=L14`; R=`G18,G17,H22,J22,K22,K21`,
G=`K18,L21,M21,M22,N22,L18`, B=`M18,N19,N18,K16,L16,M20` for bits 0..5.
The exact order is in `constraint/rgb_lcd_800x480.cst`.

The timing is 800 active pixels by 480 lines with totals 1056 x 525 and
positive-active data enable, negative sync pulses. Use a PLL output near
33.264 MHz (`1056*525*60`) for `pixel_clk`; do not reuse the audio clock.
The supplied 800x480 `.fs` is a prebuilt demonstration bitstream, not source
code and not a replacement for this module.

The local `instrument_24_rgb_top` project supplies a separate 33.333 MHz PLL
clock (1000 MHz VCO divided by 30), giving approximately 60.125 Hz refresh.
`lcd_status_bridge` transfers a complete 56-bit snapshot from the audio
domain; the renderer latches it at frame boundaries. RGB/DE/HS/VS are
registered on the falling pixel edge for rising-edge capture. The 24 key
cells now occupy 33 pixels each, from x=4 to x=795, so the last key fits.
The LCD output timing budget remains provisional until checked against the
actual panel datasheet and hardware. See `INSTRUMENT_24_RGB_INTEGRATION.md`.

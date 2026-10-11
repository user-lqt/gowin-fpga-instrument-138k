# ESP32-C3 BLE to FPGA UART

The FPGA accepts 115200 baud, 8 data bits, no parity, 1 stop bit. The ESP32
uses GPIO20 as UART RX and GPIO21 as UART TX. Cross the signals:

| ESP32-C3 | FPGA | Function |
|---|---|---|
| GPIO21 / TX | J13 pad marked C18 (`ble_uart_rx`) | phone commands into FPGA |
| GPIO20 / RX | J13 pad marked C19 (`ble_uart_tx`) | FPGA return line, currently idle high |
| GND | FPGA GND | common reference |

Both are 3.3 V logic. Do not connect the ESP32 5 V pin to an FPGA I/O. Power
the ESP32 from its USB 5 V input or a regulated 5 V supply; use common ground.
The assigned package balls C18/C19 are valid bank-2 3.3 V pins and unused by
the other project ports. Match the J13 silk labels when wiring.

## Command frame

Write five bytes to the Nordic UART Service RX characteristic:

`A5 CMD NOTE VELOCITY CHECKSUM`

`CHECKSUM = A5 XOR CMD XOR NOTE XOR VELOCITY`.
`CMD=90` is NOTE_ON, `CMD=80` is NOTE_OFF. NOTE is the MIDI note number
(K1 is normally 60), and velocity is 1..127. Invalid checksum and unknown
commands are ignored. A BLE event has priority if it arrives on the same FPGA
clock as a physical key event.

Examples:

| Action | Hex to write |
|---|---|
| K1 / C4 on, velocity 100 | `A5 90 3C 64 6D` |
| K1 off | `A5 80 3C 00 19` |
| K8 / G4 on, velocity 100 | `A5 90 43 64 12` |

Use Write Request in nRF Connect. The existing ESP32 firmware forwards these
bytes transparently; no BLE packet framing is added.

## nRF Connect for Mobile

1. Flash and run `E:\Gowin\Prj_music\esp32c3\bluetooth` with ESP-IDF 6.0.
2. Open nRF Connect, scan, connect to `FPGA-Instrument`.
3. Open service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`.
4. Write to RX characteristic `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`.
5. Select HEX input and Write Request, then send one five-byte frame at a time.
6. For a note-off, send the corresponding `80` frame. The TX characteristic
   (`...0003...`) is only for future FPGA diagnostics; subscribe if desired.

Before connecting the FPGA, loop ESP32 GPIO21 TX to GPIO20 RX and send
`50 49 4E 47 0A`; the BLE TX notification should echo `PING` and newline.

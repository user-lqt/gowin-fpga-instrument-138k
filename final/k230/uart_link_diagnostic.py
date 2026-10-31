# -*- coding: utf-8 -*-
"""Run directly in CanMV IDE; no camera, models or project imports required.

Uses the 12-pin GPIO header: UART3 / pin 5 IO32 TX / pin 3 IO33 RX.
TX -> Tang Mega dock J13-35 (C20), GND -> FPGA GND; 3.3 V TTL.
Changes FPGA parameters intentionally, but sends no notes. Hold a physical key
to hear the test. Normal completion leaves piano at 25 percent volume.
Stop the gesture program before running this file. Do not save as main.py.
"""
import time
from machine import UART, FPIOA


def write_parameter(uart, command, value):
    frame = bytes((0xA5, command, value, 0, 0xA5 ^ command ^ value))
    written = uart.write(frame)
    if written != len(frame):
        raise OSError("UART write failed: expected 5 bytes, returned %s" % written)
    print("UART accepted 5 bytes:", " ".join("%02X" % b for b in frame))
    print("This is NOT an FPGA acknowledgement.")


def main():
    print("K230 UART LINK DIAGNOSTIC V2 GPIO HEADER")
    print("UART3: header pin 5 IO32 TX / pin 3 IO33 RX, 115200 8N1")
    print("TX -> FPGA J13-35/C20; connect common GND; RX unused")
    print("Camera/LCD are not started. Observe FPGA LCD and actual sound.")
    fpioa = FPIOA()
    fpioa.set_function(32, fpioa.UART3_TXD, ie=0, oe=1, pu=1)
    fpioa.set_function(33, fpioa.UART3_RXD, ie=1, oe=0, pu=1)
    # Default UART format: 8 data bits, no parity, one stop bit.
    uart = UART(UART.UART3, 115200)
    try:
        time.sleep_ms(1500)
        steps = (
            (0xB4, 0, "MUTE: FPGA volume should become 0"),
            (0xB5, 0, "PIANO: timbre ID 0"),
            (0xB4, 25, "VOLUME 25%: FPGA raw UI value 32/127"),
            (0xB4, 50, "VOLUME 50%: FPGA raw UI value 64/127"),
            (0xB4, 25, "VOLUME 25%: FPGA raw UI value 32/127"),
            (0xB5, 1, "GUITAR: timbre ID 1; release/repress key to listen"),
            (0xB5, 2, "BELL: timbre ID 2; release/repress key to listen"),
            (0xB5, 0, "PIANO: timbre ID 0; release/repress key to listen"),
        )
        for command, value, label in steps:
            print("\nEXPECTED:", label)
            write_parameter(uart, command, value)
            time.sleep_ms(3000)
        print("DONE. Expected final FPGA setting: piano, volume 25%.")
        print("If all writes accepted but FPGA never changed: check TX/GND/pin/bitstream.")
        print("If this works but gestures do not: investigate the gesture runtime/UART pin setup.")
    finally:
        uart.deinit()


if __name__ == "__main__":
    main()

# -*- coding: utf-8 -*-
"""UART wiring test without camera/models. Stop with the IDE stop button.

The instrument's volume is changed intentionally. Hold one physical key to
listen. No NOTE_ON is sent; ending the script leaves volume 25%, piano.
"""
import sys
import time

if "/sdcard" not in sys.path:
    sys.path.append("/sdcard")
from k230_fpga_uart import FpgaLink, CMD_VOLUME, CMD_TIMBRE


def main():
    link = FpgaLink()
    try:
        # Allow time for the FPGA's audio initialization after joint power-up.
        time.sleep_ms(1500)
        steps = ((CMD_VOLUME, 0), (CMD_TIMBRE, 0), (CMD_VOLUME, 25),
                 (CMD_VOLUME, 50), (CMD_VOLUME, 25), (CMD_TIMBRE, 1), (CMD_TIMBRE, 2),
                 (CMD_TIMBRE, 0))
        for command, value in steps:
            frame = link.send(command, value)
            print("TX", " ".join("%02X" % byte for byte in frame),
                  "volume %" if command == CMD_VOLUME else "timbre ID", value)
            time.sleep_ms(2000)
        print("Done. The FPGA should now be at 25% volume, piano.")
    finally:
        link.deinit()


if __name__ == "__main__":
    main()

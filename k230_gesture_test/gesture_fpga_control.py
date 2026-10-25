# -*- coding: utf-8 -*-
"""Run this launcher in CanMV IDE after copying all three files to /sdcard.

Requires gesture_page_control_test.py and k230_fpga_uart.py on the K230.
"""
import sys

for root in ("/sdcard", "/sdcard/app"):
    if root not in sys.path:
        sys.path.append(root)

from k230_fpga_uart import FpgaLink
from gesture_page_control_test import main


def run():
    link = FpgaLink()
    try:
        print("K230 UART3: 115200 8N1; 12-pin header pin 5 IO32 TX -> FPGA J13-35/C20")
        print("No startup overwrite. Only confirmed volume/timbre changes transmit.")
        print("Transmit only; the K230 display does not confirm FPGA reception.")
        main(fpga_link=link)
    finally:
        link.deinit()


if __name__ == "__main__":
    run()

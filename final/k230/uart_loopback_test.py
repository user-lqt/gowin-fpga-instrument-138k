# -*- coding: utf-8 -*-
"""K230 physical UART loopback; run directly in CanMV IDE, not PC Python.

Power off before wiring. Disconnect K230 TX from FPGA J13-35.
Bridge ONLY header pin 5 (IO32 TX) and pin 3 (IO33 RX). Never bridge power.
Keep normal K230 power and USB IDE connection. No FPGA/model/camera needed.
Passing validates the TX/RX pair but does not identify which wire is TX.
"""
import time
from machine import UART, FPIOA


def hex_bytes(data):
    return " ".join("%02X" % value for value in data) if data else "(none)"


def exchange(uart, payload):
    # Discard old data with a bound, so an active unrelated sender cannot hang us.
    for _ in range(20):
        if not uart.any():
            break
        uart.read(128)
    written = uart.write(payload)
    if written != len(payload):
        raise OSError("UART write expected %d bytes, got %s" % (len(payload), written))
    received = bytearray()
    started = time.ticks_ms()
    while time.ticks_diff(time.ticks_ms(), started) < 500:
        if uart.any():
            chunk = uart.read(128)
            if chunk:
                received.extend(chunk)
                if len(received) >= len(payload):
                    break
        time.sleep_ms(5)
    return bytes(received)


def main():
    print("K230 UART LOOPBACK V2: UART3 IO32 TX / IO33 RX, 115200 8N1")
    print("Disconnect FPGA signal. Bridge GPIO header pins 5 and 3 before running.")
    fpioa = FPIOA()
    fpioa.set_function(32, fpioa.UART3_TXD, ie=0, oe=1, pu=1)
    fpioa.set_function(33, fpioa.UART3_RXD, ie=1, oe=0, pu=1)
    uart = UART(UART.UART3, 115200)
    passed = 0
    try:
        time.sleep_ms(500)
        for number in range(10):
            # Sequence number prevents a stale previous echo from passing.
            payload = bytes((0x55, 0xAA, 0x00, 0xFF, number, number ^ 0xFF))
            received = exchange(uart, payload)
            matched = received == payload
            passed += int(matched)
            print("%02d %s TX=[%s] RX=[%s]" %
                  (number + 1, "PASS" if matched else "FAIL",
                   hex_bytes(payload), hex_bytes(received)))
            time.sleep_ms(250)
        print("RESULT: %d/10 PASS" % passed)
        if passed == 10:
            print("External UART pair works. This does NOT distinguish TX from RX.")
            print("Remove bridge with power off, then connect actual TX to FPGA C20.")
        elif passed == 0:
            print("No reliable loopback: check connector, TX/RX bridge and UART mapping.")
        else:
            print("Intermittent loopback: check contacts and remove other signal connections.")
    finally:
        uart.deinit()


if __name__ == "__main__":
    main()

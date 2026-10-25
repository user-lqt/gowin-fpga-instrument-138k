# -*- coding: utf-8 -*-
"""K230 -> FPGA parameter link, 115200 baud / 8N1, binary frames.

Uses the Yahboom 12-pin GPIO header: pin 5 IO32 TX, pin 3 IO33 RX, UART3.
No startup sync, periodic overwrite or audio output.
"""

CMD_VOLUME = 0xB4
CMD_TIMBRE = 0xB5
# Match instrument_24_rgb_top: piano, guitar, bell.
TIMBRE_IDS = (0, 1, 2)
NOTE_KEEPALIVE_MS = 250


def make_note_frame(command, note, velocity=0):
    if command not in (0x90, 0x80, 0xB6):
        raise ValueError("Unknown note command")
    if not isinstance(note, int) or not 0 <= note <= 127:
        raise ValueError("Note must be 0..127")
    if not isinstance(velocity, int) or not 0 <= velocity <= 127:
        raise ValueError("Velocity must be 0..127")
    if command != 0x90 and velocity != 0:
        raise ValueError("Release/keepalive velocity must be zero")
    return bytes((0xA5, command, note, velocity, 0xA5 ^ command ^ note ^ velocity))


def make_frame(command, value):
    if command == CMD_VOLUME:
        if not isinstance(value, int) or not 0 <= value <= 100 or value % 5:
            raise ValueError("Volume must be 0, 5, 10, ... 100 percent")
    elif command == CMD_TIMBRE:
        if not isinstance(value, int) or value not in (0, 1, 2):
            raise ValueError("Timbre ID must be 0=piano, 1=guitar or 2=bell")
    else:
        raise ValueError("Unknown FPGA parameter command")
    # Same five-byte framing as the instrument, with two new command IDs.
    return bytes((0xA5, command, value, 0, 0xA5 ^ command ^ value))


class HeaderUart:
    """12-pin header UART; distinct from the vendor IO9/IO10 UART1 connector."""
    def __init__(self):
        from machine import UART, FPIOA
        self.fpioa = FPIOA()
        self.fpioa.set_function(32, self.fpioa.UART3_TXD, ie=0, oe=1, pu=1)
        self.fpioa.set_function(33, self.fpioa.UART3_RXD, ie=1, oe=0, pu=1)
        self.uart = UART(UART.UART3, 115200)

    def send(self, frame):
        written = self.uart.write(frame)
        if written != len(frame):
            raise OSError("UART3 write expected %d bytes, got %s" % (len(frame), written))
        return written

    def deinit(self):
        self.uart.deinit()


class FpgaLink:
    def __init__(self, transport=None):
        if transport is None:
            transport = HeaderUart()
        self.transport = transport
        self.last_volume = None
        self.last_timbre = None
        self.sent_commands = 0
        self.active_note = None
        self.last_note_keepalive = None

    def attach(self, control):
        """Adopt UI baseline without changing the instrument at startup."""
        self.last_volume = control.volume
        self.last_timbre = control.timbre

    def send(self, command, value):
        frame = make_frame(command, value)
        return self.send_frame(frame)

    def send_frame(self, frame):
        # One raw binary packet; no text encoding or added newline.
        result = self.transport.send(frame)
        if isinstance(result, int) and result != len(frame):
            raise OSError("UART short write: %d of %d bytes" % (result, len(frame)))
        self.sent_commands += 1
        return frame

    def set_note(self, note):
        if note is not None:
            make_note_frame(0x90, note, 100)  # Validate before stopping the old note.
        if note == self.active_note:
            return False
        if self.active_note is not None:
            self.send_frame(make_note_frame(0x80, self.active_note))
            self.active_note = None
        if note is not None:
            # Track before write so cleanup can release even after a short write.
            self.active_note = note
            self.send_frame(make_note_frame(0x90, note, 100))
        self.last_note_keepalive = None
        return True

    def keepalive(self, now_ms):
        if self.active_note is None:
            return
        if self.last_note_keepalive is None:
            self.last_note_keepalive = now_ms
            return
        import time
        if time.ticks_diff(now_ms, self.last_note_keepalive) >= NOTE_KEEPALIVE_MS:
            self.send_frame(make_note_frame(0xB6, self.active_note))
            self.last_note_keepalive = now_ms

    def publish(self, control, event):
        """Only real gesture changes send commands; pause/loss preserves sound."""
        if event in ("NOTE", "INPUT_MODE"):
            return self.set_note(getattr(control, "touch_note", None))
        # 明确触摸允许重发同一值，便于在 FPGA 编码器改值后重新选定。
        if event == "TOUCH_VOLUME" or event == "VOLUME" and control.volume != self.last_volume:
            self.send(CMD_VOLUME, control.volume)
            self.last_volume = control.volume
            return True
        if event == "TOUCH_TIMBRE" or event in ("TIMBRE", "INCREASE", "DECREASE") and control.timbre != self.last_timbre:
            self.send(CMD_TIMBRE, TIMBRE_IDS[control.timbre])
            self.last_timbre = control.timbre
            return True
        return False

    def sync(self, control):
        """Explicit manual sync only, e.g. after an FPGA reset."""
        self.send(CMD_VOLUME, control.volume)
        self.send(CMD_TIMBRE, TIMBRE_IDS[control.timbre])
        self.attach(control)

    def deinit(self):
        try:
            self.set_note(None)
        finally:
            self.transport.deinit()

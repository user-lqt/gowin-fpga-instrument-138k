# -*- coding: utf-8 -*-
"""K230 -> FPGA parameter link, 115200 baud / 8N1, binary frames.

Uses the Yahboom module's external UART connector, as its supplied demos do.
No camera, FPIOA remapping, startup sync, periodic overwrite or audio output.
"""

CMD_VOLUME = 0xB4
CMD_TIMBRE = 0xB5
# Match instrument_24_rgb_top: piano, guitar, bell.
TIMBRE_IDS = (0, 1, 2)


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


class FpgaLink:
    def __init__(self, transport=None):
        if transport is None:
            from ybUtils.YbUart import YbUart
            transport = YbUart(baudrate=115200)
        self.transport = transport
        self.last_volume = None
        self.last_timbre = None
        self.sent_commands = 0

    def attach(self, control):
        """Adopt UI baseline without changing the instrument at startup."""
        self.last_volume = control.volume
        self.last_timbre = control.timbre

    def send(self, command, value):
        frame = make_frame(command, value)
        # One raw binary packet; no text encoding or added newline.
        result = self.transport.send(frame)
        if isinstance(result, int) and result != len(frame):
            raise OSError("UART short write: %d of %d bytes" % (result, len(frame)))
        self.sent_commands += 1
        return frame

    def publish(self, control, event):
        """Only real gesture changes send commands; pause/loss preserves sound."""
        if event == "VOLUME" and control.volume != self.last_volume:
            self.send(CMD_VOLUME, control.volume)
            self.last_volume = control.volume
            return True
        if event in ("INCREASE", "DECREASE") and control.timbre != self.last_timbre:
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
        self.transport.deinit()

"""Host tests: exact wire bytes, validation and gesture-to-UART policy."""
from types import SimpleNamespace
import unittest

from k230_fpga_uart import FpgaLink, make_frame, CMD_VOLUME, CMD_TIMBRE


class Transport:
    def __init__(self):
        self.frames = []
        self.closed = False

    def send(self, frame):
        self.frames.append(frame)
        return len(frame)

    def deinit(self):
        self.closed = True


class FpgaUartTests(unittest.TestCase):
    def setUp(self):
        self.transport = Transport()
        self.link = FpgaLink(self.transport)
        self.control = SimpleNamespace(volume=50, timbre=0)
        self.link.attach(self.control)

    def test_exact_wire_frames(self):
        self.assertEqual(make_frame(CMD_VOLUME, 50), bytes.fromhex("A5 B4 32 00 23"))
        self.assertEqual(make_frame(CMD_TIMBRE, 2), bytes.fromhex("A5 B5 02 00 12"))
        for value in range(0, 101, 5):
            frame = make_frame(CMD_VOLUME, value)
            self.assertEqual(len(frame), 5)
            self.assertEqual(frame[4], frame[0] ^ frame[1] ^ frame[2] ^ frame[3])

    def test_invalid_values_never_transmit(self):
        for command, value in ((CMD_VOLUME, -5), (CMD_VOLUME, 105),
                               (CMD_VOLUME, 51), (CMD_VOLUME, 50.0),
                               (CMD_TIMBRE, 3), (CMD_TIMBRE, -1), (0x90, 60)):
            with self.assertRaises(ValueError):
                self.link.send(command, value)
        self.assertEqual(self.transport.frames, [])

    def test_no_startup_or_periodic_write(self):
        for event in (None, "PAGE", "RESUME", "PAUSE", None):
            self.link.publish(self.control, event)
        self.assertEqual(self.transport.frames, [])

    def test_volume_changes_once_and_zero_mutes(self):
        self.control.volume = 55
        self.assertTrue(self.link.publish(self.control, "VOLUME"))
        self.assertFalse(self.link.publish(self.control, "VOLUME"))
        self.control.volume = 0
        self.assertTrue(self.link.publish(self.control, "VOLUME"))
        self.assertEqual(self.transport.frames[-1], make_frame(CMD_VOLUME, 0))

    def test_three_timbres_match_fpga_order(self):
        self.control.timbre = 1
        self.link.publish(self.control, "INCREASE")
        self.link.publish(self.control, "INCREASE")
        self.control.timbre = 2
        self.link.publish(self.control, "INCREASE")
        self.control.timbre = 0
        self.link.publish(self.control, "DECREASE")
        self.assertEqual(self.transport.frames, [make_frame(CMD_TIMBRE, 1),
                                                 make_frame(CMD_TIMBRE, 2),
                                                 make_frame(CMD_TIMBRE, 0)])

    def test_pause_and_hand_loss_never_send_mute(self):
        self.control.volume = 0
        self.control.timbre = 1
        for event in (None, "PAUSE", "PAGE", "RESUME"):
            self.link.publish(self.control, event)
        self.assertEqual(self.transport.frames, [])

    def test_explicit_resync_and_release(self):
        self.link.sync(self.control)
        self.assertEqual(self.transport.frames, [make_frame(CMD_VOLUME, 50),
                                                 make_frame(CMD_TIMBRE, 0)])
        self.link.deinit()
        self.assertTrue(self.transport.closed)

    def test_short_write_does_not_accept_change(self):
        self.transport.send = lambda frame: 2
        self.control.volume = 55
        with self.assertRaises(OSError):
            self.link.publish(self.control, "VOLUME")
        self.assertEqual(self.link.last_volume, 50)

    def test_real_gesture_logic_sends_all_three_matching_timbres(self):
        from test_static_control_logic import load_logic, pose
        logic = load_logic()
        control = logic["PageControl"]()
        self.link.attach(control)
        self.assertEqual(logic["TIMBRE_NAMES"], ("钢琴", "吉他", "编钟"))
        for kind in ("V_SIGN", "PALM", "V_SIGN", "PALM", "V_SIGN", "PALM", "V_SIGN"):
            for _ in range(6):
                # Release with a neutral valid pose between same-direction steps.
                points = pose(kind) if kind != "OTHER" else pose("PALM")
                event = control.update_pose(points, 100)
                self.link.publish(control, event)
        self.assertEqual([frame[2] for frame in self.transport.frames], [1, 2, 0, 1])
        self.assertTrue(all(frame[1] == CMD_TIMBRE for frame in self.transport.frames))


if __name__ == "__main__":
    unittest.main()

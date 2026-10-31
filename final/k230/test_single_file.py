"""Check the deployed entry point and real gesture-to-wire path without K230 HW."""
import ast
import math
from pathlib import Path
from types import SimpleNamespace
import unittest

from test_static_control_logic import pose, palm_at_target


PATH = Path(__file__).with_name("main.py")


def load_single_file():
    tree = ast.parse(PATH.read_text(encoding="utf-8"))
    names = {"finger_angles", "palm_geometry", "pose_kind", "palm_height_reading",
             "volume_level", "PageControl", "HeightVolumeFilter", "FpgaLink", "HeaderUart",
             "make_frame", "make_note_frame", "run", "TouchControl", "poll_touch", "draw_page_frame",
             "screen_xy", "draw_overlay_text", "control_status", "main"}
    nodes = [node for node in tree.body if isinstance(node, ast.Assign)
             or isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in names]
    namespace = {"math": math}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(PATH), "exec"), namespace)
    return namespace


class SingleFileTests(unittest.TestCase):
    def setUp(self):
        self.logic = load_single_file()

    def test_standalone_imports_and_autostart(self):
        tree = ast.parse(PATH.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom):
                self.assertNotIn(node.module, ("gesture_page_control_test",
                                               "gesture_fpga_control", "k230_fpga_uart"))
        # Execute the actual main guard, so boot cannot silently enter screen-only mode.
        calls = []
        exec(compile(ast.Module(body=[tree.body[-1]], type_ignores=[]), str(PATH), "exec"),
             {"__name__": "__main__", "run": lambda: calls.append("run")})
        self.assertEqual(calls, ["run"])

    def test_launcher_passes_link_and_releases_on_error(self):
        calls = []
        link = SimpleNamespace(deinit=lambda: calls.append("closed"))
        def main(fpga_link):
            self.assertIs(fpga_link, link)
            calls.append("linked")
            raise RuntimeError("camera failed")
        self.logic.update(FpgaLink=lambda: link, main=main, print=lambda *args: None)
        with self.assertRaisesRegex(RuntimeError, "camera failed"):
            self.logic["run"]()
        self.assertEqual(calls, ["linked", "closed"])

    def test_real_gestures_send_timbres_and_quantized_volume(self):
        frames = []
        transport = SimpleNamespace(send=lambda frame: frames.append(frame))
        link = self.logic["FpgaLink"](transport)
        control = self.logic["PageControl"]()
        link.attach(control)
        self.assertEqual(frames, [])
        def feed(points, count):
            for _ in range(count):
                link.publish(control, control.update_pose(points, 100))
        for kind in ("V_SIGN", "PALM", "V_SIGN", "PALM", "V_SIGN"):
            feed(pose(kind), 6)
        self.assertEqual(frames, [bytes.fromhex("A5 B5 01 00 11"),
                                  bytes.fromhex("A5 B5 02 00 12"),
                                  bytes.fromhex("A5 B5 00 00 10")])
        feed(pose("PALM"), 3)
        feed(pose("FIST"), 6)
        feed(palm_at_target(100), 60)
        volume_frames = [frame for frame in frames if frame[1] == 0xB4]
        self.assertGreater(len(volume_frames), 0)
        self.assertEqual(volume_frames[-1][2], 100)
        feed(palm_at_target(0), 90)
        self.assertEqual(frames[-1], bytes.fromhex("A5 B4 00 00 11"))
        for frame in frames:
            self.assertEqual(frame[4], frame[0] ^ frame[1] ^ frame[2] ^ frame[3])
            if frame[1] == 0xB4:
                self.assertEqual(frame[2] % 5, 0)
        count = len(frames)
        feed(None, 10)
        self.assertEqual(len(frames), count)
        self.assertEqual(link.sent_commands, count)


if __name__ == "__main__":
    unittest.main()

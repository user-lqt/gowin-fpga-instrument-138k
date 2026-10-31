"""Host-only logic checks; no K230 camera/model execution is simulated."""
import ast
import math
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parent


def load_logic(filename):
    path = ROOT / filename
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    functions = {"measure_pinch", "finger_angles", "pose_kind", "screen_xy",
                 "control_status", "draw_music_frame"}
    classes = {"PinchControl", "WaveEvidence", "MusicControl"}
    nodes = [node for node in tree.body if isinstance(node, ast.Assign)
             or isinstance(node, ast.FunctionDef) and node.name in functions
             or isinstance(node, ast.ClassDef) and node.name in classes]
    namespace = {"math": math}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec"), namespace)
    return namespace


def points_for_ratio(ratio):
    points = [0.0] * 42
    for i, xy in ((0, (200, 300)), (9, (200, 200)),
                  (4, (200, 150)), (8, (200 + ratio * 100, 150))):
        points[i * 2:i * 2 + 2] = xy
    return points


def hand(pinch=False, dx=0, ratio=0.8):
    xy = [(320, 360), (285, 315), (260, 295), (238, 272), (215, 250),
          (280, 260), (280, 205), (280, 150), (280, 120),
          (320, 250), (320, 195), (320, 140), (320, 105),
          (360, 265), (360, 210), (360, 160), (360, 130),
          (395, 285), (395, 245), (395, 210), (395, 180)]
    if pinch:
        xy[4] = (280 + 110 * ratio, 120)
        xy[10:13] = [(320, 220), (320, 240), (320, 290)]
        xy[14:17] = [(360, 240), (360, 265), (360, 300)]
        xy[18:21] = [(395, 260), (395, 285), (395, 320)]
    return [value for x, y in xy for value in (x + dx, y)]


def scores(index, score=0.3):
    result = [0.0] * 27
    result[index] = score
    return result


class PinchTests(unittest.TestCase):
    def test_both_programs_use_slow_settings(self):
        for filename in ("pinch_screen_test.py", "gesture_music_control_test.py"):
            logic = load_logic(filename)
            self.assertEqual(logic["OPEN_RATIO"], 1.60)
            self.assertEqual(logic["SMOOTH_TIME_MS"], 350.0)
            self.assertEqual(logic["VOLUME_DEADBAND"], 3.0)
            self.assertEqual(logic["MAX_RATE_PER_SECOND"], 35.0)

    def test_deadband_rejects_small_target_noise(self):
        for filename in ("pinch_screen_test.py", "gesture_music_control_test.py"):
            c = load_logic(filename)["PinchControl"]()
            c.update(points_for_ratio(0.875), 100)
            for i in range(20):
                ratio = 0.875 + (0.025 if i % 2 else -0.025)
                c.update(points_for_ratio(ratio), 100)
            self.assertAlmostEqual(c.percent, 50.0)
            c.update(points_for_ratio(1.60), 100)
            self.assertGreater(c.percent, 50.0)
            self.assertLessEqual(c.percent, 53.5)

    def test_slew_limit_both_directions_and_stalled_frame(self):
        c = load_logic("pinch_screen_test.py")["PinchControl"]()
        c.update(points_for_ratio(0.15), 100)
        previous = c.percent
        for _ in range(40):
            c.update(points_for_ratio(1.60), 100)
            self.assertTrue(0 <= c.percent - previous <= 3.500001)
            previous = c.percent
        c.update(points_for_ratio(0.15), 10000)
        self.assertLessEqual(previous - c.percent, 5.250001)
        previous = c.percent
        for _ in range(40):
            c.update(points_for_ratio(0.15), 100)
            self.assertTrue(0 <= previous - c.percent <= 3.500001)
            previous = c.percent

    def test_smoothing_consistent_across_frame_rates(self):
        cls = load_logic("pinch_screen_test.py")["PinchControl"]
        results = []
        for step in (20, 50, 100):
            c = cls(deadband=0, max_rate=0)
            c.update(points_for_ratio(0.15), step)
            for _ in range(1000 // step):
                c.update(points_for_ratio(1.60), step)
            results.append(c.percent)
        for value in results:
            self.assertAlmostEqual(value, 100 * (1 - math.exp(-1000 / 350)))

    def test_endpoints_invalid_points_and_reset(self):
        c = load_logic("pinch_screen_test.py")["PinchControl"]()
        self.assertEqual(c.update(points_for_ratio(0), 100)["percent"], 0)
        self.assertIsNone(c.update(None, 100))
        self.assertIsNone(c.percent)
        self.assertEqual(c.update(points_for_ratio(2), 100)["percent"], 100)
        bad = points_for_ratio(0.8)
        bad[8] = float("nan")
        self.assertIsNone(c.update(bad, 100))


class MusicTests(unittest.TestCase):
    def setUp(self):
        self.logic = load_logic("gesture_music_control_test.py")
        self.c = self.logic["MusicControl"]()

    def arm(self):
        for _ in range(5):
            self.c.update_pose(hand(), 100)
        self.assertEqual(self.c.mode, "WAVE")

    def test_pose_geometry_and_scale(self):
        pose = self.logic["pose_kind"]
        self.assertEqual(pose(hand()), "PALM")
        self.assertEqual(pose(hand(pinch=True)), "PINCH")
        self.assertEqual(pose(None), "NONE")
        measure = self.logic["measure_pinch"]
        p = hand(pinch=True)
        scaled = [v * 0.7 for v in p]
        self.assertAlmostEqual(measure(p)[1], measure(scaled)[1])

    def test_volume_holds_during_palm_wave_and_loss(self):
        self.arm()
        self.assertEqual(self.c.volume(), 50)
        self.c.update_pose(hand(dx=60), 100)
        self.assertEqual(self.c.volume(), 50)
        self.c.update_pose(None, 100)
        self.assertEqual(self.c.volume(), 50)
        self.assertEqual(self.c.timbre, 0)
        self.assertEqual(self.c.mode, "RELEASE")

    def test_stationary_and_vertical_movements_do_not_switch(self):
        self.arm()
        for _ in range(10):
            self.c.update_wave(scores(11))
        self.assertEqual(self.c.timbre, 0)
        moved = hand(dx=20)
        for i in range(1, 42, 2):
            moved[i] += 50
        self.c.update_pose(moved, 100)
        self.assertIsNone(self.c.update_wave(scores(11)))
        self.assertEqual(self.c.timbre, 0)

    def test_screen_displacement_decides_direction_despite_model_mirror(self):
        self.arm()
        self.c.update_pose(hand(dx=-60), 100)
        self.c.update_wave(scores(11))
        self.assertEqual(self.c.update_wave(scores(11)), "LEFT")

    def test_single_right_event_rearm_and_timeout(self):
        self.arm()
        self.c.update_pose(hand(dx=60), 100)
        self.assertIsNone(self.c.update_wave(scores(11)))
        self.assertEqual(self.c.update_wave(scores(11)), "RIGHT")
        self.assertEqual(self.c.timbre, 1)
        for _ in range(15):
            self.c.update_pose(hand(), 100)
            self.assertIsNone(self.c.update_wave(scores(11)))
        self.assertEqual(self.c.mode, "RELEASE")
        self.assertEqual(self.c.timbre, 1)
        for _ in range(3):
            self.c.update_pose(None, 100)
        self.assertEqual(self.c.mode, "IDLE")
        self.arm()
        self.c.update_pose(hand(), 2000)
        self.assertEqual(self.c.mode, "RELEASE")
        self.assertEqual(self.c.timbre, 1)

    def test_left_event_wrap_and_swapped_control(self):
        self.arm()
        self.c.update_pose(hand(dx=-60), 100)
        self.c.update_wave(scores(12))
        self.assertIsNone(self.c.update_wave(scores(17)))
        self.assertEqual(self.c.update_wave(scores(12)), "LEFT")
        self.assertEqual(self.c.timbre, 1)
        self.logic["SWAP_LEFT_RIGHT"] = True
        self.c = self.logic["MusicControl"]()
        self.arm()
        self.c.update_pose(hand(dx=60), 100)
        self.c.update_wave(scores(11))
        self.assertEqual(self.c.update_wave(scores(11)), "LEFT")

    def test_reacquired_pinch_ramps_from_saved_volume(self):
        self.c.update_pose(None, 100)
        self.assertEqual(self.c.volume(), 50)
        self.c.update_pose(hand(pinch=True, ratio=1.60), 100)
        self.assertEqual(self.c.volume(), 50)
        self.c.update_pose(hand(pinch=True, ratio=1.60), 100)
        self.assertGreater(self.c.volume(), 50)
        self.assertLessEqual(self.c.pinch.percent, 53.5)

    def test_evidence_resets_and_memory_stays_bounded(self):
        evidence = self.logic["WaveEvidence"]()
        self.assertIsNone(evidence.update(scores(11)))
        self.assertIsNone(evidence.update(scores(2)))
        self.assertIsNone(evidence.update(scores(11)))
        self.assertIsNone(evidence.update(scores(12)))
        self.assertEqual(evidence.update(scores(12)), "LEFT")
        for _ in range(100):
            evidence.update(scores(12))
        self.assertLessEqual(len(evidence.scores), 4)
        self.assertIsNone(evidence.update([float("nan")] * 27))

    def test_screen_handles_no_hand_and_each_mode(self):
        class Canvas:
            def __getattr__(self, name):
                def record(*args, **kwargs):
                    if name == "draw_string_advanced":
                        self.texts.append(args[3])
                    if name == "draw_rectangle":
                        x, y, width, height = args
                        assert x >= 0 and y >= 0 and x + width <= 640 and y + height <= 480
                return record
        class Pipeline:
            display_size = [640, 480]
            osd_img = Canvas()
        pl = Pipeline()
        for mode in ("IDLE", "WAVE", "RELEASE"):
            self.c.mode = mode
            for points in (None, hand()):
                pl.osd_img.texts = []
                self.logic["draw_music_frame"](pl, None, points, self.c, 10)
                self.assertTrue(any("50%" in text for text in pl.osd_img.texts))


if __name__ == "__main__":
    unittest.main(verbosity=2)

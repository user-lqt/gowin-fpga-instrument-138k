"""Host checks for palm-height volume and static gestures; does not run K230 AI."""
import ast
import math
from pathlib import Path
import unittest
from test_control_logic import hand


PATH = Path(__file__).with_name("gesture_page_control_test.py")


def load_logic():
    tree = ast.parse(PATH.read_text(encoding="utf-8"))
    names = {"finger_angles", "palm_geometry", "pose_kind", "palm_height_reading", "screen_xy",
             "control_status", "draw_overlay_text", "draw_page_frame", "PageControl", "HeightVolumeFilter", "volume_level"}
    nodes = [node for node in tree.body if isinstance(node, ast.Assign)
             or isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in names]
    namespace = {"math": math}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(PATH), "exec"), namespace)
    return namespace


def pose(kind="PALM"):
    points = hand()
    if kind != "PALM":
        for finger in range(1, 5):
            if kind == "V_SIGN" and finger in (1, 2):
                continue
            if kind == "ONE" and finger == 1:
                continue
            if kind == "DECREASE" and finger in (1, 2, 3):
                continue
            base = 1 + finger * 4
            x, y = points[base * 2:base * 2 + 2]
            points[(base + 1) * 2:(base + 4) * 2] = [x, y - 25, x, y, x, y + 35]
    if kind == "FIST":
        points[6:10] = [285, 300, 305, 325]
    elif kind == "INCREASE":
        points[6:10] = [250, 265, 245, 225]
    return points


def transform(points, angle=0, scale=1, mirror=False, dx=0, dy=0):
    radians = math.radians(angle)
    result = []
    for index in range(21):
        x = (points[index * 2] - 320) * scale * (-1 if mirror else 1)
        y = (points[index * 2 + 1] - 240) * scale
        result.extend((320 + x * math.cos(radians) - y * math.sin(radians) + dx,
                       240 + x * math.sin(radians) + y * math.cos(radians) + dy))
    return result


def palm_at_target(percent):
    # Use actual 21-point hand geometry at a known camera height.
    points = pose()
    cy = sum(points[index * 2 + 1] for index in (0, 5, 9, 13, 17)) / 5
    desired_y = (0.78 - percent / 100 * (0.78 - 0.40)) * 480
    return transform(points, dy=desired_y - cy)


class StaticControlTests(unittest.TestCase):
    def setUp(self):
        self.logic = load_logic()
        self.c = self.logic["PageControl"]()

    def feed(self, kind, frames=1, dt=100):
        return self.feed_points(None if kind is None else pose(kind), frames, dt)

    def feed_points(self, points, frames=1, dt=100):
        events = []
        for _ in range(frames):
            event = self.c.update_pose(points, dt)
            if event is not None:
                events.append(event)
        return events

    def select_volume(self):
        self.assertEqual(self.feed("FIST", 6), ["PAGE"])
        self.assertEqual(self.c.page, 1)

    def start_height(self):
        self.select_volume()
        self.assertEqual(self.feed_points(palm_at_target(50), 6), ["RESUME"])
        self.assertTrue(self.c.height_active)

    def test_three_distinct_poses_mirror_scale_and_rotate(self):
        for kind in ("PALM", "FIST", "V_SIGN"):
            for mirror in (False, True):
                for angle in (-25, 0, 25):
                    points = transform(pose(kind), mirror=mirror, angle=angle, scale=0.8)
                    self.assertEqual(self.logic["pose_kind"](points), kind)

    def test_removed_gestures_cannot_change_parameters(self):
        for kind in ("ONE", "INCREASE", "DECREASE"):
            self.assertEqual(self.logic["pose_kind"](pose(kind)), "OTHER")
            self.assertEqual(self.feed(kind, 30), [])
            self.assertEqual(self.c.confirm_progress(), 0)
        self.assertEqual((self.c.page, self.c.timbre, self.c.volume), (0, 0, 50))

    def test_one_gesture_cycles_all_pages_once_per_hold(self):
        for expected in (1, 0, 1, 0):
            self.assertEqual(self.feed("FIST", 50), ["PAGE"])
            self.assertEqual(self.c.page, expected)
            self.feed(None, 6)

    def test_timbres_wrap_and_never_change_volume(self):
        for expected in (1, 2, 0, 1):
            self.assertEqual(self.feed("V_SIGN", 50), ["TIMBRE"])
            self.assertEqual(self.c.timbre, expected)
            self.feed("PALM", 3)
        self.assertEqual(self.c.volume, 50)

    def test_wrong_page_has_no_progress_or_fake_execution(self):
        self.select_volume()
        self.feed("PALM", 3)
        self.assertEqual(self.feed("V_SIGN", 50), [])
        self.assertEqual(self.c.confirm_progress(), 0)
        self.assertIn("此页用张掌", self.logic["control_status"](self.c))
        self.assertEqual(self.c.timbre, 0)

    def test_visible_progress_only_for_executable_action(self):
        self.feed("V_SIGN", 3)
        self.assertTrue(0 < self.c.confirm_progress() < 100)
        self.assertEqual(self.feed("V_SIGN", 3), ["TIMBRE"])
        self.assertEqual(self.c.confirm_progress(), 0)
        self.assertIn("已执行", self.logic["control_status"](self.c))

    def test_brief_missing_hand_does_not_repeat_action(self):
        for action in ("FIST", "V_SIGN"):
            self.c = self.logic["PageControl"]()
            first = self.feed(action, 6)
            self.assertEqual(len(first), 1)
            for _ in range(6):
                self.feed(None, 2)
                self.assertEqual(self.feed(action, 8), [])

    def test_action_to_action_flicker_needs_neutral_release(self):
        self.feed("V_SIGN", 6)
        self.assertEqual(self.feed("FIST", 20), [])
        self.assertEqual(self.feed("V_SIGN", 20), [])
        self.assertEqual((self.c.page, self.c.timbre), (0, 1))
        self.feed("PALM", 3)
        self.assertEqual(self.feed("FIST", 6), ["PAGE"])

    def test_short_neutral_release_does_not_repeat(self):
        self.feed("V_SIGN", 6)
        self.feed("PALM", 2)
        self.assertEqual(self.feed("V_SIGN", 8), [])
        self.feed("PALM", 3)
        self.assertEqual(self.feed("V_SIGN", 6), ["TIMBRE"])

    def test_hold_uses_elapsed_time_and_minimum_frames(self):
        for dt in (30, 100, 150):
            self.c = self.logic["PageControl"]()
            count = 0
            for _ in range(1000 // dt):
                count += len(self.feed("V_SIGN", 1, dt))
            self.assertEqual(count, 1)
        self.c = self.logic["PageControl"]()
        self.assertEqual(self.feed("V_SIGN", 2, 150), [])
        self.assertEqual(self.c.timbre, 0)

    def test_frame_stall_does_not_confirm_or_release(self):
        self.feed("V_SIGN", 6)
        self.c.update_pose(None, 3000)
        self.assertEqual(self.feed("V_SIGN", 8), [])
        self.c = self.logic["PageControl"]()
        self.start_height()

    def test_palm_requires_confirmation_and_stops_on_first_other_pose(self):
        self.select_volume()
        self.assertEqual(self.feed_points(palm_at_target(100), 5), [])
        self.assertFalse(self.c.height_active)
        self.assertEqual(self.feed_points(palm_at_target(100), 1), ["RESUME"])
        self.assertEqual(self.c.volume, 50)
        self.feed_points(palm_at_target(100), 5)
        previous = self.c.volume
        self.assertGreater(previous, 50)
        self.feed("ONE")
        self.assertFalse(self.c.height_active)
        self.assertEqual(self.feed_points(palm_at_target(0), 5), [])
        self.assertEqual(self.c.volume, previous)
        self.assertEqual(self.feed_points(palm_at_target(0), 1), ["RESUME"])

    def test_volume_reaches_limits_with_five_percent_steps(self):
        self.start_height()
        for target in (100, 0):
            self.feed_points(palm_at_target(target), 100)
            self.assertEqual(self.c.volume, target)
        self.assertEqual(self.c.timbre, 0)

    def test_no_hand_or_stall_retains_volume_and_stops_height(self):
        for dt in (100, 3000):
            self.c = self.logic["PageControl"]()
            self.start_height()
            self.feed_points(palm_at_target(100), 8)
            previous = self.c.volume
            self.c.update_pose(None, dt)
            self.assertFalse(self.c.height_active)
            self.assertEqual(self.c.volume, previous)
            self.assertEqual(self.c.page, 1)

    def test_page_change_stops_height_before_confirmation(self):
        self.start_height()
        self.feed_points(palm_at_target(100), 8)
        previous = self.c.volume
        self.feed("FIST")
        self.assertFalse(self.c.height_active)
        self.assertEqual(self.feed("FIST", 5), ["PAGE"])
        self.assertEqual((self.c.page, self.c.volume), (0, previous))

    def test_height_jitter_and_horizontal_motion_do_not_adjust(self):
        self.start_height()
        for i in range(80):
            points = transform(palm_at_target(50 + (1 if i % 2 else -1)), dx=30 if i % 2 else -30)
            self.c.update_pose(points, 100)
        self.assertEqual(self.c.volume, 50)

    def test_invalid_geometry_does_not_execute(self):
        for points in (None, [0] * 42, [float("nan")] * 42):
            self.assertEqual(self.feed_points(points, 20), [])
        self.assertEqual(self.c.timbre, 0)

    def test_overlay_fits_and_shows_execution_not_false_confirmation(self):
        texts = []
        class Canvas:
            def __getattr__(self, name):
                def record(*args, **kwargs):
                    if name == "draw_rectangle":
                        assert not kwargs.get("fill", False)
                    if name == "draw_string_advanced":
                        x, y, size, text = args
                        assert x >= 0 and y >= 0 and y + size <= 480
                        assert x + sum(size if ord(c) > 127 else size * 0.65 for c in text) <= 640
                        texts.append(text)
                return record
        class Pipeline:
            display_size = [640, 480]
            osd_img = Canvas()
        for kind in (None, "FIST", "PALM", "V_SIGN", "ONE", "INCREASE"):
            self.c = self.logic["PageControl"]()
            for _ in range(8):
                self.feed(kind)
                for page in (0, 1):
                    self.c.page = page
                    self.c.link_active = True
                    self.logic["draw_page_frame"](Pipeline(), None, None, self.c, 10)
        self.assertTrue(any("串口已发" in text for text in texts))
        self.assertFalse(any("100%" in text and "确认" in text for text in texts))


class HeightFilterTests(unittest.TestCase):
    def setUp(self):
        self.logic = load_logic()
        self.filter = self.logic["HeightVolumeFilter"](50)

    def test_geometry_mapping_and_clamp(self):
        for target in (-5, 0, 25, 50, 75, 100, 105):
            with self.subTest(target=target):
                reading = self.logic["palm_height_reading"](palm_at_target(target))
                self.assertIsNotNone(reading)
                self.assertAlmostEqual(reading[2], max(0, min(100, target)))
        self.assertIsNone(self.logic["palm_height_reading"](None))

    def test_fingertip_motion_does_not_change_height_target(self):
        points = palm_at_target(50)
        expected = self.logic["palm_height_reading"](points)
        for index in (4, 8, 12, 16, 20):
            points[index * 2 + 1] += 25
        self.assertEqual(self.logic["palm_height_reading"](points), expected)

    def test_filter_rejects_micro_jitter_and_follows_larger_change(self):
        for i in range(100):
            self.assertEqual(self.filter.update(50 + (2 if i % 2 else -2), 100), 50)
        for _ in range(3):
            self.filter.update(60, 100)
        self.assertGreater(self.filter.percent, 50)
        self.assertEqual(self.filter.level, 55)
        self.assertLess(self.filter.percent, 60)

    def test_rate_limit_both_directions_and_no_overshoot(self):
        for target in (100, 0, 100):
            for _ in range(100):
                previous = self.filter.percent
                output = self.filter.update(target, 100)
                self.assertLessEqual(abs(self.filter.percent - previous), 2.000001)
                self.assertEqual(output % 5, 0)
                self.assertTrue(0 <= self.filter.percent <= 100)
            self.assertEqual(self.filter.level, target)

    def test_small_response_consistent_across_frame_rates(self):
        results = []
        for dt in (20, 50, 100):
            f = self.logic["HeightVolumeFilter"](50)
            for _ in range(1000 // dt):
                f.update(60, dt)
            results.append(f.percent)
        for value in results:
            self.assertAlmostEqual(value, 60 - 10 * math.exp(-1000 / 500))

    def test_reset_keeps_value_and_limits_reentry(self):
        self.filter.update(100, 100)
        self.filter.reset(27)
        self.assertEqual(self.filter.percent, 25)
        self.assertEqual(self.filter.update(100, 100), 25)
        self.assertEqual(self.filter.update(100, 100), 30)

    def test_volume_levels_include_mute_and_only_five_percent_steps(self):
        level = self.logic["volume_level"]
        self.assertEqual(level(-5), 0)
        self.assertEqual(level(103), 100)
        for raw in range(101):
            self.assertIn(level(raw), range(0, 101, 5))
        for target in (100, 0):
            outputs = [self.filter.update(target, 100) for _ in range(100)]
            self.assertTrue(all(value % 5 == 0 for value in outputs))
            self.assertEqual(outputs[-1], target)

    def test_step_boundary_jitter_does_not_toggle_levels(self):
        for i in range(80):
            self.assertEqual(self.filter.update(52.5 + (0.2 if i % 2 else -0.2), 100), 50)
        for _ in range(30):
            self.filter.update(56, 100)
        self.assertEqual(self.filter.level, 55)
        for i in range(80):
            self.assertEqual(self.filter.update(52.5 + (0.2 if i % 2 else -0.2), 100), 55)


if __name__ == "__main__":
    unittest.main(verbosity=2)

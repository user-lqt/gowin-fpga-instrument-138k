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
        points = None if kind is None else pose(kind)
        return self.feed_points(points, frames, dt)

    def feed_points(self, points, frames=1, dt=100):
        return [event for _ in range(frames)
                if (event := self.c.update_pose(points, dt)) is not None]

    def select_volume(self):
        self.assertEqual(self.feed("ONE", 6), ["PAGE"])
        self.assertTrue(self.c.enabled)
        self.assertEqual(self.c.page, 1)

    def start_height(self):
        self.select_volume()
        self.assertEqual(self.feed_points(palm_at_target(50), 5), ["RESUME"])
        self.assertTrue(self.c.height_active)
        self.assertEqual(self.c.volume, 50)

    def test_actual_geometry_six_gestures_and_handedness(self):
        for kind in ("ONE", "V_SIGN", "PALM", "FIST", "INCREASE", "DECREASE"):
            for mirror in (False, True):
                for scale in (0.65, 1.0, 1.2):
                    with self.subTest(kind=kind, mirror=mirror, scale=scale):
                        points = transform(pose(kind), scale=scale, mirror=mirror, dx=12, dy=-8)
                        self.assertEqual(self.logic["pose_kind"](points), kind)

    def test_finger_poses_ignore_rotation_and_downward_thumb_is_inactive(self):
        for kind in ("ONE", "V_SIGN", "PALM", "FIST", "DECREASE"):
            self.assertEqual(self.logic["pose_kind"](transform(pose(kind), angle=180)), kind)
        self.assertEqual(self.logic["pose_kind"](transform(pose("INCREASE"), angle=180)), "OTHER")
        self.assertEqual(self.logic["pose_kind"](transform(pose("INCREASE"), angle=90)), "OTHER")

    def test_invalid_missing_tiny_and_degenerate_hand(self):
        for points in (None, [], [0] * 42, transform(pose(), scale=0.1)):
            self.assertEqual(self.logic["pose_kind"](points), "NONE")
        for value in (math.nan, math.inf, -1, 700):
            points = pose()
            points[8] = value
            self.assertEqual(self.logic["pose_kind"](points), "NONE")
        points = pose()
        points[6:8] = points[8:10]
        self.assertEqual(self.logic["pose_kind"](points), "OTHER")

    def test_initially_paused_and_adjustment_cannot_unlock(self):
        self.assertEqual((self.c.enabled, self.c.mode), (False, "PAUSED"))
        self.assertEqual(self.feed("INCREASE", 40), [])
        self.assertEqual((self.c.page, self.c.volume, self.c.timbre), (0, 50, 0))

    def test_pages_are_direct_and_holding_does_not_toggle(self):
        self.assertEqual(self.feed("ONE", 30), ["PAGE"])
        self.assertEqual(self.c.page, 1)
        self.assertEqual(self.feed("V_SIGN", 30), ["PAGE"])
        self.assertEqual(self.c.page, 0)
        self.feed("PALM", 6)
        self.assertEqual(self.feed("V_SIGN", 10), ["PAGE"])
        self.assertEqual((self.c.page, self.c.volume, self.c.timbre), (0, 50, 0))

    def test_confirmation_requires_time_and_multiple_frames(self):
        self.assertEqual(self.feed("ONE", 3), [])
        self.assertFalse(self.c.enabled)
        self.assertGreater(self.c.confirm_progress(), 0)
        self.assertLess(self.c.confirm_progress(), 100)
        self.assertEqual(self.feed("ONE", 2), ["PAGE"])
        self.assertEqual(self.c.confirm_progress(), 0)
        other = self.logic["PageControl"]()
        self.assertIsNone(other.update_pose(pose("ONE"), 400))
        self.assertIsNone(other.update_pose(pose("ONE"), 400))
        self.assertFalse(other.enabled)

    def test_unrecognized_pose_interrupts_confirmation(self):
        self.feed("ONE", 3)
        unknown = transform(pose("INCREASE"), angle=90)
        self.c.update_pose(unknown, 100)
        self.assertEqual(self.c.pose, "OTHER")
        self.assertEqual(self.c.confirm_progress(), 0)
        self.assertEqual(self.feed("ONE", 3), [])
        self.assertFalse(self.c.enabled)
        self.assertEqual(self.feed("ONE", 2), ["PAGE"])

    def test_timbre_changes_once_per_held_pose(self):
        self.feed("V_SIGN", 6)
        self.assertEqual(self.feed("INCREASE", 70), ["INCREASE"])
        self.assertEqual(self.c.timbre, 1)
        self.assertEqual(self.feed("DECREASE", 70), ["DECREASE"])
        self.assertEqual(self.c.timbre, 0)
        self.assertEqual(self.c.volume, 50)

    def test_old_volume_adjustment_gestures_do_nothing(self):
        self.select_volume()
        self.assertEqual(self.feed("INCREASE", 50), [])
        self.assertEqual(self.feed("DECREASE", 50), [])
        self.assertEqual((self.c.volume, self.c.timbre), (50, 0))
        self.assertFalse(self.c.height_active)

    def test_non_palm_immediately_stops_height_and_resume_requires_confirmation(self):
        self.start_height()
        self.feed_points(palm_at_target(100), 4)
        previous = self.c.volume
        self.assertGreater(previous, 50)
        unknown = transform(pose("INCREASE"), angle=90)
        self.assertIsNone(self.c.update_pose(unknown, 100))
        self.assertFalse(self.c.height_active)
        self.assertEqual(self.feed_points(palm_at_target(0), 3), [])
        self.assertEqual(self.c.volume, previous)
        self.assertEqual(self.feed_points(palm_at_target(0), 2), ["RESUME"])
        self.assertEqual(self.c.volume, previous)
        self.feed_points(palm_at_target(0), 4)
        self.assertLess(self.c.volume, previous)
        self.assertGreater(self.c.volume, 0)

    def test_brief_pose_noise_does_not_duplicate_step(self):
        self.feed("V_SIGN", 6)
        self.feed("INCREASE", 5)
        unknown = transform(pose("INCREASE"), angle=90)
        self.c.update_pose(unknown, 100)
        self.assertEqual(self.feed("INCREASE", 5), [])
        self.assertEqual((self.c.timbre, self.c.volume), (1, 50))

    def test_released_pose_can_trigger_next_step(self):
        self.feed("V_SIGN", 6)
        self.feed("INCREASE", 5)
        self.feed("DECREASE", 5)
        unknown = transform(pose("INCREASE"), angle=90)
        for _ in range(3):
            self.c.update_pose(unknown, 100)
        self.assertEqual(self.feed("DECREASE", 5), ["DECREASE"])
        self.assertEqual((self.c.timbre, self.c.volume), (0, 50))

    def test_fist_needs_confirmation_then_palm_resumes_same_page(self):
        self.start_height()
        self.feed_points(palm_at_target(100), 3)
        previous = self.c.volume
        self.feed("FIST")
        self.assertFalse(self.c.height_active)
        self.assertTrue(self.c.enabled)
        self.assertEqual(self.feed("FIST", 2), ["PAUSE"])
        self.assertEqual((self.c.enabled, self.c.mode), (False, "PAUSED"))
        self.assertEqual(self.feed("DECREASE", 30), [])
        self.assertEqual(self.feed_points(palm_at_target(0), 5), ["RESUME"])
        self.assertEqual((self.c.page, self.c.volume, self.c.timbre), (1, previous, 0))

    def test_no_hand_pauses_immediately_even_on_long_frame(self):
        for dt in (100, 700):
            self.feed("ONE", 6)
            self.c.update_pose(None, dt)
            self.assertEqual((self.c.enabled, self.c.mode), (False, "PAUSED"))
            self.assertEqual((self.c.page, self.c.volume), (1, 50))
            self.assertEqual(self.feed("INCREASE", 20), [])
            self.assertEqual(self.feed("PALM", 6), ["RESUME"])
            self.feed(None)

    def test_frame_stall_requires_resume_and_never_catches_up(self):
        self.start_height()
        self.feed_points(palm_at_target(100), 3)
        previous = self.c.volume
        self.assertIsNone(self.c.update_pose(palm_at_target(0), 3000))
        self.assertFalse(self.c.enabled)
        self.assertFalse(self.c.height_active)
        self.assertEqual(self.c.volume, previous)
        self.assertEqual(self.feed("INCREASE", 30), [])
        self.assertEqual(self.feed_points(palm_at_target(0), 5), ["RESUME"])
        self.assertEqual(self.c.volume, previous)
        self.feed_points(palm_at_target(0), 4)
        self.assertLess(self.c.volume, previous)

    def test_limits_clamp_without_wrapping(self):
        for page, volume, timbre, kind, expected in (
            (0, 50, 2, "INCREASE", (50, 2)),
            (0, 50, 0, "DECREASE", (50, 0)),
        ):
            self.c = self.logic["PageControl"]()
            self.c.page, self.c.volume, self.c.timbre = page, volume, timbre
            self.feed("PALM", 6)
            self.feed(kind, 80)
            self.assertEqual((self.c.volume, self.c.timbre), expected)

    def test_moving_palm_on_timbre_page_does_not_adjust(self):
        self.feed("V_SIGN", 6)
        self.feed("PALM", 5)
        for dx, dy in ((30, 0), (-30, 0), (0, -45), (0, 45)):
            for _ in range(8):
                self.assertIsNone(self.c.update_pose(transform(pose(), dx=dx, dy=dy), 100))
        self.assertEqual((self.c.page, self.c.volume, self.c.timbre), (0, 50, 0))

    def test_palm_is_confirmed_before_height_changes_volume(self):
        self.select_volume()
        self.assertFalse(self.c.height_active)
        self.assertEqual(self.feed_points(palm_at_target(100), 3), [])
        self.assertEqual(self.c.volume, 50)
        self.assertFalse(self.c.height_active)
        self.assertEqual(self.feed_points(palm_at_target(100), 2), ["RESUME"])
        self.assertEqual(self.c.volume, 50)
        self.feed_points(palm_at_target(100), 4)
        self.assertEqual(self.c.volume, 55)

    def test_height_controls_both_directions_and_reaches_limits(self):
        self.start_height()
        self.feed_points(palm_at_target(100), 80)
        self.assertEqual(self.c.volume, 100)
        self.assertEqual(self.c.timbre, 0)
        self.feed_points(palm_at_target(0), 100)
        self.assertEqual(self.c.volume, 0)
        self.assertEqual(self.c.timbre, 0)

    def test_horizontal_motion_and_small_height_jitter_keep_volume(self):
        self.start_height()
        for i in range(80):
            target = 50 + (1 if i % 2 else -1)
            self.c.update_pose(transform(palm_at_target(target), dx=40 if i % 2 else -40), 100)
        self.assertEqual(self.c.volume, 50)
        self.assertTrue(self.c.height_active)

    def test_page_switch_stops_height_before_confirmation_and_retains_volume(self):
        self.start_height()
        self.feed_points(palm_at_target(100), 8)
        previous = self.c.volume
        self.feed("V_SIGN")
        self.assertFalse(self.c.height_active)
        self.assertEqual(self.c.volume, previous)
        self.assertEqual(self.feed("V_SIGN", 4), ["PAGE"])
        self.assertEqual(self.c.page, 0)
        self.feed("INCREASE", 20)
        self.assertEqual((self.c.timbre, self.c.volume), (1, previous))
        self.feed("ONE", 5)
        self.assertEqual(self.c.page, 1)
        self.assertEqual(self.c.volume, previous)
        self.assertFalse(self.c.height_active)

    def test_loss_retains_modified_volume_and_clears_height_target(self):
        self.start_height()
        self.feed_points(palm_at_target(100), 4)
        previous = self.c.volume
        self.assertIsNotNone(self.c.height_target)
        self.feed(None)
        self.assertFalse(self.c.enabled)
        self.assertFalse(self.c.height_active)
        self.assertIsNone(self.c.height_target)
        self.assertEqual(self.c.volume, previous)
        self.assertEqual(self.feed_points(palm_at_target(0), 5), ["RESUME"])
        self.assertEqual(self.c.volume, previous)

    def test_draw_all_poses_and_confirmation_states(self):
        class Canvas:
            def __getattr__(self, name):
                def record(*args, **kwargs):
                    if name == "draw_rectangle":
                        x, y, width, height = args
                        assert x >= 0 and y >= 0 and x + width <= 640 and y + height <= 480
                        assert not kwargs.get("fill", False), "UI must not paint opaque panels over video"
                    if name == "draw_string_advanced":
                        x, y, size, text = args
                        assert x >= 0 and y >= 0 and y + size <= 480
                        assert x + sum(size if ord(c) > 127 else size * 0.65 for c in text) <= 640
                    if name == "draw_circle":
                        x, y, radius = args
                        assert 0 <= x < 640 and 0 <= y < 480
                return record
        class Pipeline:
            display_size = [640, 480]
            osd_img = Canvas()
        for kind in (None, "ONE", "V_SIGN", "INCREASE", "DECREASE", "FIST", "PALM"):
            self.feed(kind, 3)
            for page in (0, 1):
                for volume in (0, 50, 100):
                    self.c.page, self.c.volume = page, volume
                    self.logic["draw_page_frame"](Pipeline(), [0, 1, 0, 0, 640, 480],
                                                 None if kind is None else pose(kind), self.c, 15)
        self.c = self.logic["PageControl"]()
        self.start_height()
        for target in (100, 0, 50):
            points = palm_at_target(target)
            self.feed_points(points, 30)
            self.assertTrue(self.c.height_active)
            self.logic["draw_page_frame"](Pipeline(), None, points, self.c, 15)
        self.feed("FIST", 3)
        self.logic["draw_page_frame"](Pipeline(), None, pose("FIST"), self.c, 15)


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

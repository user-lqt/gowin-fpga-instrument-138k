"""Plan display tests without opening windows or connecting devices."""

import unittest

from latency_gui import plan_progress_text


class PlanTextTests(unittest.TestCase):
    def test_completed_and_missing_counts_are_distinct(self):
        text = plan_progress_text(
            [1, 2, 21], {1: 4, 2: 1, 21: 0}, {1: 3, 2: 3, 21: 3})
        self.assertIn("还需 2 个键、共 5 条", text)
        self.assertIn("K1：已可用 4 次 / 目标 3 次 / 无需补测", text)
        self.assertIn("K2：已可用 1 次 / 目标 3 次 / 还需 2 次", text)
        self.assertIn("K21：已可用 0 次 / 目标 3 次 / 还需 3 次", text)

    def test_additive_targets(self):
        text = plan_progress_text([8], {8: 4}, {8: 7})
        self.assertIn("已可用 4 次 / 目标 7 次 / 还需 3 次", text)
        self.assertIn("共 3 条", text)

    def test_complete_plan_never_shows_negative_missing(self):
        text = plan_progress_text([1, 7], {1: 3, 7: 5}, {1: 3, 7: 3})
        self.assertIn("还需 0 个键、共 0 条", text)
        self.assertEqual(text.count("无需补测"), 2)
        self.assertNotIn("还需 -", text)

    def test_wiring_order_is_preserved(self):
        text = plan_progress_text([1, 7, 13, 19], dict.fromkeys([1, 7, 13, 19], 1),
                                  dict.fromkeys([1, 7, 13, 19], 3))
        positions = [text.index(f"K{k}：") for k in (1, 7, 13, 19)]
        self.assertEqual(positions, sorted(positions))


if __name__ == "__main__":
    unittest.main()

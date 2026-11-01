import copy
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from latency_budget_report import digest, joint_display, lookup, section


class BudgetReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "app"
        self.trial = self.root / "measurements/raw/latency/fw/K01/medium/trial_001"
        self.trial.mkdir(parents=True)
        self.csv = self.root / "measurements/raw/logic/logic_001/digital.csv"
        self.csv.parent.mkdir(parents=True)
        self.csv.write_text("digital evidence")
        (self.trial / "trial.json").write_text(json.dumps(dict(key=1, trial=1)))
        (self.trial / "joint_capture.json").write_text(json.dumps(dict(
            digital_csv="../../../../../logic/logic_001/digital.csv")))
        for name in ("ch1.bin", "ch2.bin", "metadata.json"):
            (self.trial / name).write_bytes(name.encode())
        sources = {str(p): digest(p) for p in [self.csv] + list(self.trial.iterdir())}
        self.summary_file = self.root / "measurements/reports/latency/budget/summary.json"
        self.summary_file.parent.mkdir(parents=True)
        self.result = dict(
            audio_latest_scope_s=.0136, b_window_scope_s=[.01, .010026],
            unbudgeted_timing_envelope_ms=3.805, conditional_upper_ms=None,
            conditional_below_5ms=None, error_budget_verified=False,
            logic_csv_sha256=digest(self.csv),
        )
        value = (3.805+.030+.000002)/(1-25e-6)
        self.budget = dict(
            source_sha256=sources, observations=[dict(
                key=1, trial=1, original_delay_ms=3.6, original_envelope_ms=3.805,
                phase_increment_us=20.77, conditional_scenarios_ms={"0": value, "10": value+.001})],
            uniform_empirical_allowance_us=30, scope_assumed_base_ppm=25,
            scope_official_typical_base_ppm=15, scope_aging_ppm_per_year=5,
            channel_skew_max_ns=2, count=1, keys=[dict(key=1)])
        self.register()

    def register(self):
        self.summary_file.write_text(json.dumps(self.budget), encoding="utf-8")
        self.registry = self.summary_file.parents[1] / "budget_profiles.json"
        self.registry.write_text(json.dumps(dict(profiles=[dict(
            summary=str(self.summary_file.relative_to(self.root)),
            sha256=digest(self.summary_file), original_root=str(self.root))])))

    def test_matched_render_does_not_change_measurements_or_verdict_flags(self):
        original = copy.deepcopy(self.result)
        profile = lookup(self.trial, self.result, self.root)
        self.assertEqual(profile["status"], "matched")
        display = joint_display(self.result, profile)
        self.assertIn("30 µs", display["allowance"])
        text = section(profile, self.summary_file.parent, self.root)
        for word in ("典型值", "不是保证上限", "非本机已知校准年龄", "20.770"):
            self.assertIn(word, text)
        self.assertNotIn(str(self.root), text)
        self.assertEqual(self.result, original)
        self.assertIsNone(profile["conditional_below_5ms"])
        self.assertFalse(profile["error_budget_verified"])

    def test_all_six_source_types_must_match(self):
        for source in self.budget["source_sha256"]:
            with self.subTest(source=source):
                path = Path(source)
                before = path.read_bytes()
                path.write_bytes(before + b" ")
                self.assertEqual(lookup(self.trial, self.result, self.root)["status"], "unmatched")
                path.write_bytes(before)

    def test_new_trial_not_assigned_old_budget(self):
        trial = self.trial.with_name("trial_002")
        shutil.copytree(self.trial, trial)
        profile = lookup(trial, self.result, self.root)
        self.assertEqual(profile["status"], "unmatched")
        self.assertNotIn("已完成", joint_display(self.result, profile)["verdict"])

    def test_changed_timing_rejected(self):
        for key, value in (("audio_latest_scope_s", .0137),
                           ("unbudgeted_timing_envelope_ms", 3.9),
                           ("logic_csv_sha256", "other")):
            result = {**self.result, key: value}
            self.assertEqual(lookup(self.trial, result, self.root)["status"], "unmatched")

    def test_corrupt_summary_rejected(self):
        self.summary_file.write_text("{}")
        self.assertEqual(lookup(self.trial, self.result, self.root)["status"], "unmatched")

    def test_movable_folder_uses_relative_mapping(self):
        moved = Path(self.temp.name) / "moved"
        shutil.copytree(self.root, moved)
        trial = moved / self.trial.relative_to(self.root)
        profile = lookup(trial, self.result, moved)
        self.assertEqual(profile["status"], "matched")
        text = section(profile, moved / "measurements/reports/latency/other", moved)
        self.assertIn("../budget/report.html", text)
        self.assertNotIn(str(self.root), text)

    def test_scope_only_is_not_joint_acceptance(self):
        profile = lookup(self.trial, root=self.root)
        self.assertEqual(profile["status"], "matched")
        text = section(profile, self.summary_file.parent, self.root, scope_only=True)
        self.assertIn("不能直接加到本页", text)
        self.assertIn("不改变本页判定", text)

    def test_registry_path_traversal_rejected(self):
        self.registry.write_text(json.dumps(dict(profiles=[dict(summary="../other")])))
        self.assertEqual(lookup(self.trial, self.result, self.root)["status"], "unmatched")


if __name__ == "__main__":
    unittest.main()

"""Diagnostic selections must never become acceptance decisions."""

import contextlib
import csv
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

from scan_signal_diagnostics import generate, summarize


class DiagnosticTests(unittest.TestCase):
    def test_row_mismatch_report_preserves_counts_without_acceptance(self):
        from test_scan_row_phase import RowPhaseTests
        from scan_latency_validation import row_column_mismatch
        data = RowPhaseTests().fixture()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root/"digital.csv"
            with source.open("w", newline="") as stream:
                writer = csv.writer(stream)
                writer.writerow(("t", "a", "b", "c"))
                writer.writerows(data)
            detail = row_column_mismatch(data)
            with patch("scan_signal_diagnostics.report_folder", return_value=root/"reports"):
                report, result = generate(
                    root, source, ("t", "a", "b", "c"), "行列对应未验证",
                    2_000_000, detail)
            text = report.read_text(encoding="utf-8")
            self.assertIn("50.000", text)
            self.assertIn("不要继续重复正式测量", text)
            self.assertEqual(result["row_column_phase_diagnostic"], detail)
            self.assertIsNone(result["conditional_below_5ms"])

    def test_analog_prior_contact_does_not_use_scope_time_as_logic_time(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root/"digital.csv"
            with source.open("w", newline="") as stream:
                writer = csv.writer(stream)
                writer.writerow(("t", "a", "b", "c"))
                writer.writerows(self.fixture())
            analog = np.full(5000, 3.3)
            analog[100:104] = 0
            detail = dict(category="prior_analog_column_contact", channel="示波器列信号",
                          first_main_s=.00023,
                          events=[dict(start_s=.00005, end_s=.000052,
                                       width_us=2., before_first_main_us=180.)])
            with patch("scan_signal_diagnostics.report_folder", return_value=root/"reports"), \
                    patch("latency_waveforms.load", return_value=(
                        (analog, analog), .5e-6, {"raw_sha256": {"CH1": "verified"}})):
                report, result = generate(root, source, ("t", "a", "b", "c"),
                                          "前置模拟列接触", 2_000_000, detail)
            text = report.read_text(encoding="utf-8")
            self.assertIn("尚未通过共同列同步", text)
            self.assertIn("180.000", text)
            self.assertTrue((report.parent/"prior_analog_contact.png").is_file())
            self.assertFalse((report.parent/"rejected_events.png").exists())
            self.assertIsNone(result["conditional_below_5ms"])

    def fixture(self):
        t = np.arange(5000) * .5e-6
        phase = np.arange(5000) % 400
        a = np.where(phase < 60, 0, 1)
        b = np.where((phase >= 50) & (phase < 105), 0, 1)
        a[phase == 65] = 0
        c = np.ones(len(t), dtype=int)
        c[(t > .001) & ((a == 0) | (b == 0))] = 0
        return np.column_stack((t, a, b, c))

    def test_period_diagnostic_does_not_hide_overlap_or_short_pulses(self):
        result = summarize(self.fixture())
        self.assertEqual(result["validation_status"], "not_determined")
        self.assertIsNone(result["conditional_below_5ms"])
        self.assertGreater(result["channels"][0]["low_pulses_under_1us"], 10)
        np.testing.assert_allclose(result["channels"][0]["long_pulse_period_us"], 200)
        self.assertGreater(result["row_overlap_total_us"], 50)

    def test_no_major_pulses_does_not_claim_period(self):
        data = self.fixture()
        data[:, 1:] = 1
        result = summarize(data)
        self.assertIsNone(result["channels"][0]["long_pulse_period_us"])
        self.assertIsNone(result["conditional_below_5ms"])

    def test_diagnostic_is_additive_and_original_csv_unchanged(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "digital.csv"
            with source.open("w", newline="") as stream:
                writer = csv.writer(stream)
                writer.writerow(("t", "a", "b", "c"))
                writer.writerows(self.fixture())
            original = source.read_bytes()
            detail = dict(channel="列信号", rejected_count=1, total_short_count=99,
                          events=[dict(start_s=.0010325, end_s=.001033,
                                       width_us=.5, distance_to_scan_boundary_us=7.5)])
            with patch("scan_signal_diagnostics.report_folder", return_value=root / "reports"):
                report, result = generate(root, source, ("t", "a", "b", "c"),
                                          "测试错误", 2_000_000, error_details=detail)
                second, _ = generate(root, source, ("t", "a", "b", "c"), "测试错误", 2_000_000)
            self.assertNotEqual(report, second)
            self.assertTrue((report.parent / "digital_waveforms.png").is_file())
            self.assertIn("未作达标判定", report.read_text(encoding="utf-8"))
            self.assertEqual(source.read_bytes(), original)
            self.assertIsNone(result["conditional_below_5ms"])
            self.assertEqual(result["rejected_event_details"], detail)
            self.assertTrue((report.parent/"rejected_events.png").is_file())
            self.assertIn("总数不等于违规数", report.read_text(encoding="utf-8"))

    def test_joint_warning_includes_diagnostics(self):
        from capture_joint_trial import validate_saved
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stats = summarize(self.fixture())
            out = io.StringIO()
            with patch("scan_latency_validation.generate_observation", side_effect=ValueError("扫描异常")), \
                    patch("scan_signal_diagnostics.generate", return_value=(root / "report.html", stats)), \
                    patch("capture_joint_trial.report_folder", return_value=root), \
                    contextlib.redirect_stdout(out):
                validate_saved(root, root / "digital.csv", 24_000_000, 0, 0)
            line = next(line for line in out.getvalue().splitlines()
                        if line.startswith("JOINT_VALIDATION_WARNING "))
            detail = json.loads(line.split(" ", 1)[1])
            self.assertIn("200.000", detail["signal_summary"])
            self.assertEqual(detail["signal_report"], str(root / "report.html"))
            self.assertEqual(detail["validation_status"], "error")

    def test_intermediate_event_report_does_not_require_short_glitch_fields(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "digital.csv"
            with source.open("w", newline="") as stream:
                writer = csv.writer(stream)
                writer.writerow(("t", "a", "b", "c"))
                writer.writerows(self.fixture())
            detail = dict(category="intermediate_pulses", channel="列信号",
                          events=[dict(start_s=.00115, end_s=.0011515, width_us=1.5)])
            with patch("scan_signal_diagnostics.report_folder", return_value=root / "reports"):
                report, result = generate(root, source, ("t", "a", "b", "c"),
                                          "中等宽度脉冲", 2_000_000, error_details=detail)
            text = report.read_text(encoding="utf-8")
            self.assertIn("1～10 µs 独立低脉冲 1 个", text)
            self.assertIn("1.5000", text)
            self.assertIsNone(result["conditional_below_5ms"])

    def test_partial_b_has_analog_comparison_not_short_glitch_counts(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root/"digital.csv"
            with source.open("w", newline="") as stream:
                writer = csv.writer(stream)
                writer.writerow(("t", "a", "b", "c"))
                writer.writerows(self.fixture())
            original = source.read_bytes()
            detail = dict(
                category="partial_b_window", channel="B 行与列",
                b_window_logic_s=[.001025, .0010525],
                column_low_logic_s=[.001033, .0010525],
                column_onset_from_b_start_us=8,
                column_low_width_us=19.5, column_low_reaches_core_end=True,
                alignment_scale=1., alignment_offset_s=0.,
            )
            analog = np.where(self.fixture()[:, 3], 3.3, 0.)
            with patch("scan_signal_diagnostics.report_folder", return_value=root/"reports"), \
                    patch("latency_waveforms.load", return_value=((analog, analog), .5e-6,
                                                                 {"raw_sha256": {"CH1": "verified"}})):
                report, result = generate(root, source, ("t", "a", "b", "c"),
                                          "部分导通", 2_000_000, detail)
            self.assertTrue((report.parent/"partial_b_window.png").is_file())
            text = report.read_text(encoding="utf-8")
            self.assertIn("中途开始导通不等于导通后又断开", text)
            self.assertIn("8.000", text)
            self.assertEqual(source.read_bytes(), original)
            self.assertIsNone(result["conditional_below_5ms"])
            self.assertEqual(result["analog_comparison_raw_sha256"], {"CH1": "verified"})

    def test_prior_contact_report_never_calls_events_boundary_violations(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "digital.csv"
            with source.open("w", newline="") as stream:
                writer = csv.writer(stream)
                writer.writerow(("t", "a", "b", "c"))
                writer.writerows(self.fixture())
            original = source.read_bytes()
            detail = dict(
                category="prior_column_contact", channel="列信号", first_main_s=.0012,
                initial_column_low=False,
                events=[dict(start_s=.001015, end_s=.0010165, width_us=1.5,
                             before_first_main_us=185.)])
            with patch("scan_signal_diagnostics.report_folder", return_value=root / "reports"):
                report, result = generate(root, source, ("t", "a", "b", "c"),
                                          "前置列低", 2_000_000, detail)
            text = report.read_text(encoding="utf-8")
            self.assertIn("首次完整主列前超过1微秒的低段 1 个", text)
            self.assertNotIn("不符合边界规则", text)
            self.assertEqual(source.read_bytes(), original)
            self.assertIsNone(result["conditional_below_5ms"])


if __name__ == "__main__":
    unittest.main()

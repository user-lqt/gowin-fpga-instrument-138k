"""Offline post-capture classification checks."""

import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from capture_joint_trial import scope_failure_message, validate_saved


class ValidationOutcomeTests(unittest.TestCase):
    def test_automatic_attempts_and_actual_blocker_are_preserved(self):
        error = ValueError("缺少独立模拟列高证据")
        error.analysis_attempts = [
            dict(options={}, reason="首次A片段需要独立模型"),
            dict(options={"initial_a_fragments": True}, reason=str(error)),
        ]
        error.initial_analysis_error = "首次A片段需要独立模型"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = io.StringIO()
            with patch("scan_latency_validation.generate_observation", side_effect=error), \
                    patch("scan_signal_diagnostics.generate", side_effect=ValueError("无测试波形")), \
                    patch("capture_joint_trial.report_folder", return_value=root), \
                    contextlib.redirect_stdout(output):
                validate_saved(root, root/"digital.csv", 24_000_000, 0, 0)
            detail = json.loads((root/"joint_validation_error.json").read_text(encoding="utf-8"))
            self.assertIn("独立模拟列高", detail["reason"])
            self.assertEqual(detail["automatic_analysis_attempts"], error.analysis_attempts)
            self.assertEqual(detail["initial_analysis_error"], error.initial_analysis_error)
            self.assertEqual(detail["validation_status"], "error")

    def test_download_failure_preserves_specific_reason_and_paths(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "trial.json").write_text(json.dumps({
                "error_message": "CH1 请求300001–400000，已保存300000点",
                "error": "legacy exception",
            }), encoding="utf-8")
            message = scope_failure_message(root, root / "logic")
            self.assertIn("已保存300000点", message)
            self.assertIn(str(root / "logic"), message)
            self.assertIn("不计入有效次数", message)
            self.assertNotIn("legacy exception", message)

    def test_download_failure_missing_or_invalid_manifest_is_not_masked(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for content in (None, "broken", "[]", '{"error":"old reason"}'):
                if content is not None:
                    (root / "trial.json").write_text(content, encoding="utf-8")
                message = scope_failure_message(root, root / "logic")
                self.assertIn("示波器保存失败", message)
                self.assertIn(str(root / "logic"), message)
                if content and "old reason" in content:
                    self.assertIn("old reason", message)

    def test_validation_errors_preserve_completed_capture(self):
        for margin, ppm, target in (
                (0, 0, "scan_latency_validation.generate_observation"),
                (10, 50, "scan_latency_validation.generate")):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                raw = root / "trial"
                raw.mkdir()
                (raw / "ch1.bin").write_bytes(b"original")
                output = io.StringIO()
                with patch(target, side_effect=ValueError("扫描周期不符合固定八行扫描模型")), \
                        patch("capture_joint_trial.report_folder", return_value=root / "reports"), \
                        contextlib.redirect_stdout(output):
                    validate_saved(raw, root / "digital.csv", 24_000_000, margin, ppm)
                warning = next(line for line in output.getvalue().splitlines()
                               if line.startswith("JOINT_VALIDATION_WARNING "))
                prefix, data = warning.split(" ", 1)
                self.assertEqual(prefix, "JOINT_VALIDATION_WARNING")
                detail = json.loads(data)
                self.assertEqual(detail["capture_status"], "complete")
                self.assertEqual(detail["validation_status"], "error")
                self.assertIn("扫描周期", detail["reason"])
                self.assertTrue(Path(detail["diagnostic_file"]).is_file())
                self.assertEqual((raw / "ch1.bin").read_bytes(), b"original")

    def test_success_still_emits_report(self):
        output = io.StringIO()
        with patch("scan_latency_validation.generate", return_value=Path("report.html")), \
                contextlib.redirect_stdout(output):
            validate_saved(Path("trial"), Path("digital.csv"), 24_000_000, 10, 50)
        self.assertIn("Latency report: ", output.getvalue())
        self.assertNotIn("WARNING", output.getvalue())


if __name__ == "__main__":
    unittest.main()

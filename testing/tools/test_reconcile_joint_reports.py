import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from latency_session import file_digest
from reconcile_joint_reports import check_sources, failure_group, reconcile


class ReconcileTests(unittest.TestCase):
    def test_changed_sources_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "data.bin"
            source.write_bytes(b"original")
            record = {"source_sha256": {str(source): file_digest(source)}}
            check_sources(record)
            source.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "不一致"):
                check_sources(record)

    def test_missing_source_hashes_rejected(self):
        with self.assertRaisesRegex(ValueError, "缺少"):
            check_sources({})

    def test_classification_does_not_lose_specific_failures(self):
        self.assertEqual(failure_group("完整 A/B 扫描周期不足 20 个。"), "完整行扫描周期不足")
        self.assertEqual(failure_group("主列导通之前已有低电平"), "首次主列之前存在低电平")
        self.assertEqual(failure_group("列信号存在 1～10 µs 的非主脉冲，不能作为边沿短跳变排除。"),
                         "独立中等宽度脉冲")

    def test_empty_audit_generates_24_key_summary(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            audit = root / "audit.json"
            audit.write_text(json.dumps({
                "engine_sha256": file_digest(Path(__file__).with_name("scan_latency_validation.py")),
                "records": [],
            }), encoding="utf-8")
            with patch("reconcile_joint_reports.generate_observation") as generate, \
                    patch("reconcile_joint_reports.directory", return_value=root / "raw"):
                result = reconcile(audit, root / "raw", root / "output")
            generate.assert_not_called()
            self.assertEqual(len(result["keys"]), 24)
            self.assertEqual(sum(r["missing_to_3"] for r in result["keys"]), 72)
            self.assertTrue((root / "output" / "summary.md").is_file())

    def test_engine_change_does_not_create_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            audit = root / "audit.json"
            audit.write_text(json.dumps({"engine_sha256": "wrong", "records": []}))
            with patch("reconcile_joint_reports.directory", return_value=root / "raw"), \
                    self.assertRaisesRegex(ValueError, "引擎"):
                reconcile(audit, root / "raw", root / "output")
            self.assertFalse((root / "output").exists())

    def test_cross_copy_output_rejected_before_rendering(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaisesRegex(ValueError, "跨副本"):
                reconcile(root / "missing_audit.json", root / "raw", root / "output")
            self.assertFalse((root / "output").exists())


if __name__ == "__main__":
    unittest.main()

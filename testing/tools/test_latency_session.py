"""Offline tests; never connects to an instrument."""

import contextlib
import io
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import latency_session as session


class SessionTests(unittest.TestCase):
    def test_timbres_have_independent_three_trial_namespaces(self):
        self.assertEqual(session.image_folder("A" * 64, "piano", "raw"),
                         Path("raw/firmware_AAAAAAAAAAAA"))
        self.assertEqual(session.image_folder("A" * 64, "guitar", "raw"),
                         Path("raw/firmware_AAAAAAAAAAAA_guitar"))
        self.assertEqual(session.image_folder("A" * 64, "编钟", "raw"),
                         Path("raw/firmware_AAAAAAAAAAAA_bianzhong"))

    def test_video_trial_reserves_number_without_counting_in_plan(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            video = folder / "trial_016_video_test"
            video.mkdir()
            (video / "trial.json").write_text('{"status":"complete"}', encoding="utf-8")
            for name in ("metadata.json", "screen.bmp", "ch1.bin", "ch2.bin"):
                (video / name).write_bytes(b"preserved")
            self.assertEqual(session.progress(folder), ([], 17))
            summary = session.analysis_progress(folder, joint=True)
            self.assertEqual(summary["saved"], [])
            self.assertEqual(summary["next_number"], 17)

    def test_bianzhong_legacy_alias_counts_without_changing_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            path = folder/"trial_001"
            path.mkdir()
            manifest = '{"status":"complete","instrument_user_reported":"bell"}'
            (path/"trial.json").write_text(manifest, encoding="utf-8")
            for name in ("metadata.json", "screen.bmp", "ch1.bin", "ch2.bin"):
                (path/name).write_bytes(b"preserved")
            self.assertEqual(session.progress(folder, {
                "instrument_user_reported": "bianzhong"}), ([1], 2))
            self.assertEqual(session.progress(folder, {
                "instrument_user_reported": "guitar"}), ([], 2))
            self.assertEqual((path/"trial.json").read_text(encoding="utf-8"), manifest)

    def test_analysis_counts_are_separate_and_hash_bound(self):
        with tempfile.TemporaryDirectory() as tmp:
            force = Path(tmp)/"firmware_TEST"/"K01"/"medium"
            trial = force/"trial_001"
            trial.mkdir(parents=True)
            (trial/"trial.json").write_text('{"status":"complete"}', encoding="utf-8")
            (trial/"screen.bmp").write_bytes(b"BM")
            meta = {}
            for ch in (1, 2):
                raw = bytes([ch])*20
                (trial/f"ch{ch}.bin").write_bytes(raw)
                meta[f"CH{ch}"] = dict(sha256=hashlib.sha256(raw).hexdigest(),
                                        preamble="0,2,20,1,0.000001,0,0,0.01,0,0")
            (trial/"metadata.json").write_text(json.dumps(meta), encoding="utf-8")
            self.assertEqual(session.analysis_progress(force)["pending"], [1])
            evidence = trial/"evidence"
            evidence.mkdir()
            result = dict(kind="latency_evidence", raw_hashes_verified=True,
                          raw_sha256={ch: entry["sha256"] for ch, entry in meta.items()})
            (evidence/"review.json").write_text(json.dumps(result), encoding="utf-8")
            (evidence/"report.html").write_text("scope", encoding="utf-8")
            self.assertEqual(session.analysis_progress(force)["usable"], [1])
            self.assertEqual(session.analysis_progress(force, joint=True)["usable"], [])
            nested = evidence/"review_001"
            nested.mkdir()
            (nested/"review.json").write_text(json.dumps(result), encoding="utf-8")
            (nested/"report.html").write_text("scope second review", encoding="utf-8")
            self.assertEqual(session.analysis_progress(force)["usable"], [1])
            joint = trial/"scan_validation/verification_001"
            joint.mkdir(parents=True)
            (joint/"logic.csv").write_bytes(b"digital original")
            result.update(kind="joint_scan_latency",
                          logic_csv_sha256=hashlib.sha256(b"digital original").hexdigest())
            (joint/"analysis.json").write_text(json.dumps(result), encoding="utf-8")
            (joint/"report.html").write_text("joint", encoding="utf-8")
            self.assertEqual(session.analysis_progress(force, joint=True)["usable"], [1])
            (joint/"logic.csv").write_bytes(b"digital altered")
            self.assertEqual(session.analysis_progress(force, joint=True)["usable"], [])
            # Same-size mutation must also invalidate a prior matching analysis.
            (trial/"ch2.bin").write_bytes(bytes([3])*20)
            self.assertEqual(session.analysis_progress(force)["usable"], [])
            (trial/"trial.json").write_text('{"status":"invalid"}', encoding="utf-8")
            self.assertEqual(session.analysis_progress(force)["saved"], [])
            self.assertEqual(session.analysis_progress(force)["next_number"], 2)

    def test_wiring_changes_rows_not_column_for_k1_to_k7(self):
        first, seventh = session.key_wiring(1), session.key_wiring(7)
        self.assertEqual(first["column_ball"], seventh["column_ball"])
        self.assertEqual((first["a_ball"], first["b_ball"]), ("E14", "E13"))
        self.assertEqual((seventh["a_ball"], seventh["b_ball"]), ("C15", "C14"))
        self.assertEqual(session.key_wiring(24)["column_ball"], "B20")
        for key in (0, 25):
            with self.assertRaises(ValueError):
                session.key_wiring(key)

    def test_explicit_firmware_does_not_use_stale_global_reference(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "selected.fs"
            image.write_bytes(b"selected firmware")
            with patch.object(session, "VERSION", Path(tmp) / "nonexistent.json"):
                self.assertEqual(session.read_version(image),
                                 hashlib.sha256(image.read_bytes()).hexdigest().upper())
            with self.assertRaises(ValueError):
                session.describe_version(Path(tmp) / "missing.fs")

    def test_corrected_trial_not_counted_for_original_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            force = Path(tmp) / ("image_" + "A" * 12) / "K01" / "medium"
            folder = force / "trial_001"
            folder.mkdir(parents=True)
            (folder / "trial.json").write_text('{"status":"complete"}', encoding="utf-8")
            for name in ("metadata.json", "screen.bmp", "ch1.bin", "ch2.bin"):
                (folder / name).write_bytes(b"preserved")
            self.assertEqual(session.progress(force), ([1], 2))
            correction = dict(corrected_version={"sha256": "B" * 64})
            for name, field in (("trial.json", "original_trial_sha256"),
                                ("metadata.json", "original_metadata_sha256")):
                correction[field] = hashlib.sha256((folder / name).read_bytes()).hexdigest()
            (folder / "version_correction.json").write_text(json.dumps(correction), encoding="utf-8")
            self.assertEqual(session.progress(force), ([], 2))
            (folder / "metadata.json").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "不一致"):
                session.version_correction(folder)

    def test_key_selection(self):
        self.assertEqual(session.parse_keys("all"), list(range(1, 25)))
        self.assertEqual(session.parse_keys("K1-K3,7，K24 2"), [1, 2, 3, 7, 24])
        for value in ("", "0", "25", "4-2", "bad"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                session.parse_keys(value)

    def test_count_validation(self):
        self.assertEqual(session.positive_integer("1000"), 1000)
        for value in ("0", "-1", "1.5", "abc"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                session.positive_integer(value)

    def run_plan(self, arguments, responses=None):
        output = io.StringIO()
        with patch.object(session, "read_version", return_value="A" * 64), \
                patch.object(session, "progress", return_value=([1, 2], 4)), \
                patch.object(session.subprocess, "run") as capture, \
                patch("builtins.input", side_effect=responses or []), \
                patch("sys.argv", ["session"] + arguments), \
                contextlib.redirect_stdout(output):
            self.assertEqual(session.main(), 0)
            capture.assert_not_called()
        return output.getvalue()

    def test_all_keys_target_plan(self):
        output = self.run_plan(["--keys", "all", "--target", "10", "--plan"])
        self.assertEqual(output.count("累计目标 10"), 24)
        self.assertIn("K1 → K7 → K13 → K19 → K2", output)

    def test_add_plan(self):
        output = self.run_plan(["--keys", "2", "--add", "8", "--plan"])
        self.assertIn("累计目标 10", output)

    def test_interactive_selection(self):
        output = self.run_plan([], ["1-2", "2", "5", "no"])
        self.assertEqual(output.count("累计目标 7"), 2)


if __name__ == "__main__":
    unittest.main()

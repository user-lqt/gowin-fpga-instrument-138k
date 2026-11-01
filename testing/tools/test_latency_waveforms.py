"""Raw-data and onset regressions for row-based joint timing."""

import json
from pathlib import Path
import tempfile
import unittest

from latency_waveforms import load, onsets, confirmation_description
from test_review_latency_evidence import fixture


class WaveformTests(unittest.TestCase):
    def test_verified_raw_and_onset_configurations(self):
        with tempfile.TemporaryDirectory() as temp:
            trial = Path(temp)
            fixture(trial)
            (_, ch2), dt, evidence = load(trial)
            self.assertTrue(evidence["raw_hashes_verified"])
            rows = onsets(ch2, dt, .0035)
            self.assertEqual(len(rows), 18)
            self.assertTrue(all(.010 < s["onset_scope_s"] < .012 for s in rows))
            for row in rows:
                self.assertFalse(row["continuous_between_samples_verified"])
                self.assertAlmostEqual(row["confirmation_first_last_span_us"],
                                       (row["confirmation_samples"]-1)/row["rate_Hz"]*1e6)
                self.assertIn("未验证点间", confirmation_description(row))
            with self.assertRaisesRegex(ValueError, "基线不足"):
                onsets(ch2, dt, .00001)
            with self.assertRaisesRegex(ValueError, "模拟起音"):
                onsets(ch2*0, dt, .0035)

    def test_incomplete_and_inconsistent_timeaxes_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            trial = Path(temp)
            fixture(trial)
            path = trial/"trial.json"
            record = json.loads(path.read_text(encoding="utf-8"))
            record["status"] = "incomplete"
            path.write_text(json.dumps(record), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "未完整"):
                load(trial)

            record["status"] = "complete"
            path.write_text(json.dumps(record), encoding="utf-8")
            path = trial/"metadata.json"
            meta = json.loads(path.read_text(encoding="utf-8"))
            p = meta["CH2"]["preamble"].split(",")
            p[5] = "-0.02"
            meta["CH2"]["preamble"] = ",".join(p)
            path.write_text(json.dumps(meta), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "时间轴不一致"):
                load(trial)

    def test_legacy_confirmation_description_does_not_claim_continuity(self):
        text = confirmation_description({"rate_Hz": 100000})
        self.assertIn("10点", text)
        self.assertIn("90.0", text)
        self.assertIn("未验证点间", text)


if __name__ == "__main__":
    unittest.main()

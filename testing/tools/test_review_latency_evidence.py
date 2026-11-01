"""Synthetic scan/onset tests, independent of instrument availability."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np

import review_latency_evidence as review


def fixture(folder, widened=True):
    fs = 2_000_000
    t = np.arange(round(.020 * fs)) / fs
    ch1 = np.full(len(t), 122, dtype=np.uint8)
    for n in range(80):
        start = .0035 + n * .0002
        width = .00005 if widened and n >= 20 else .000025
        ch1[(t >= start) & (t < start + width)] = 40
    b = .0035 + 20 * .0002 + .000025
    onset = b + .00355
    y = np.where(t >= onset, .1 * np.sin(2 * np.pi * 1000 * (t - onset)), 0)
    ch2 = np.rint(y / .002 + 127).astype(np.uint8)
    meta = {}
    for c, data, step, ref in ((1, ch1, .04, 40), (2, ch2, .002, 127)):
        raw = data.tobytes()
        (folder / f"ch{c}.bin").write_bytes(raw)
        meta[f"CH{c}"] = dict(
            preamble=f"0,2,{len(raw)},1,{1/fs},-0.01,0,{step},{ref},0",
            sha256=hashlib.sha256(raw).hexdigest())
    (folder / "metadata.json").write_text(json.dumps(meta), encoding="utf-8")
    (folder / "trial.json").write_text(json.dumps(
        dict(status="complete", key=24, trial=7, force_label="soft", version={})), encoding="utf-8")


class LatencyEvidenceTests(unittest.TestCase):
    def test_final_cut_pulse_recovered_without_overwriting_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            fixture(folder)
            raw = np.fromfile(folder/"ch1.bin", dtype=np.uint8)
            raw[-20:] = 40
            (folder/"ch1.bin").write_bytes(raw.tobytes())
            meta = json.loads((folder/"metadata.json").read_text(encoding="utf-8"))
            meta["CH1"]["sha256"] = hashlib.sha256(raw.tobytes()).hexdigest()
            (folder/"metadata.json").write_text(json.dumps(meta), encoding="utf-8")
            first = review.generate(folder)
            old = {p: p.read_bytes() for p in (first, first.with_name("review.json"),
                                               folder/"ch1.bin", folder/"ch2.bin")}
            result = json.loads(first.with_name("review.json").read_text(encoding="utf-8"))
            self.assertIsNotNone(result["terminal_censored_pulse"])
            self.assertIn("末端截断", first.read_text(encoding="utf-8"))
            second = review.generate(folder)
            self.assertNotEqual(first, second)
            self.assertTrue(second.is_file())
            for p, content in old.items():
                self.assertEqual(p.read_bytes(), content)

    def scan(self, fragment=None):
        starts = .0035 + np.arange(60) * .0002
        stops = starts + np.where(np.arange(60) >= 20, .00005, .000025)
        if fragment:
            starts = np.insert(starts, 20, starts[19] + fragment[0])
            stops = np.insert(stops, 20, .0035 + 19*.0002 + fragment[1])
        return starts / 1e-8, stops / 1e-8

    def test_partial_B_is_used_as_earlier_reference(self):
        for onset in (26e-6, 33e-6, 48e-6):
            with self.subTest(onset=onset):
                starts, stops = self.scan((onset, 50e-6))
                result = review.scan_timing(starts, stops, 1e-8)
                self.assertAlmostEqual(result["partial"]["width_us"], (50e-6-onset)*1e6)
                self.assertAlmostEqual(result["inferred"], .0035+19*.0002+onset)
                self.assertLess(result["physical_lo"], .0035+18*.0002+25e-6)

    def test_fast_press_with_eight_single_pulses_is_valid(self):
        dt = 1e-8
        starts = .0035 + np.arange(60)*.0002
        stops = starts + np.where(np.arange(60) >= 8, .00005, .000025)
        result = review.scan_timing(starts/dt, stops/dt, dt)
        self.assertEqual(result["j"], 8)
        self.assertAlmostEqual(result["fit_period"], .0002)

    def test_too_short_single_prefix_still_rejected(self):
        dt = 1e-8
        starts = .0035 + np.arange(60)*.0002
        stops = starts + np.where(np.arange(60) >= 4, .00005, .000025)
        with self.assertRaisesRegex(ValueError, "至少需要 5"):
            review.scan_timing(starts/dt, stops/dt, dt)

    def test_double_width_from_start_reports_missing_single_stage(self):
        starts, _ = self.scan()
        with self.assertRaisesRegex(ValueError, "未观察到可识别的单触点阶段"):
            review.scan_timing(starts, starts + 51e-6 / 1e-8, 1e-8)

    def test_one_or_two_single_pulses_are_not_reported_as_absent(self):
        for count in (1, 2):
            with self.subTest(count=count):
                starts, _ = self.scan()
                stops = starts + np.where(np.arange(len(starts)) < count, 26e-6, 51e-6) / 1e-8
                with self.assertRaisesRegex(ValueError, f"初始单触点脉冲仅 {count} 个"):
                    review.scan_timing(starts, stops, 1e-8)

    def test_fragment_in_wrong_row_is_rejected(self):
        starts, stops = self.scan((80e-6, 97e-6))
        with self.assertRaisesRegex(ValueError, "部分脉冲"):
            review.scan_timing(starts, stops, 1e-8)

    def test_fragment_with_wrong_end_is_rejected(self):
        starts, stops = self.scan((28e-6, 40e-6))
        with self.assertRaisesRegex(ValueError, "部分脉冲"):
            review.scan_timing(starts, stops, 1e-8)

    def test_missing_A_frame_is_rejected(self):
        starts, stops = self.scan()
        with self.assertRaisesRegex(ValueError, "缺帧"):
            review.scan_timing(np.delete(starts, 10), np.delete(stops, 10), 1e-8)

    def test_actual_scan_phase_jump_is_rejected(self):
        starts, stops = self.scan()
        starts[25:] += 10e-6/1e-8
        stops[25:] += 10e-6/1e-8
        with self.assertRaisesRegex(ValueError, "多个"):
            review.scan_timing(starts, stops, 1e-8)

    def test_multiple_fragments_are_rejected(self):
        starts, stops = self.scan((33e-6, 50e-6))
        starts = np.insert(starts, 19, (.0035+18*.0002+33e-6)/1e-8)
        stops = np.insert(stops, 19, (.0035+18*.0002+50e-6)/1e-8)
        with self.assertRaisesRegex(ValueError, "多个"):
            review.scan_timing(starts, stops, 1e-8)

    def test_unstable_B_after_widening_is_rejected(self):
        starts, stops = self.scan()
        stops[24] = starts[24]+25e-6/1e-8
        with self.assertRaisesRegex(ValueError, "稳定"):
            review.scan_timing(starts, stops, 1e-8)

    def test_partial_pulse_full_report(self):
        self.check_partial_report(33e-6)

    def test_sub_10us_partial_pulse_is_not_silently_lost(self):
        self.check_partial_report(43e-6)

    def check_partial_report(self, partial_start):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            fixture(folder)
            meta = json.loads((folder / "metadata.json").read_text(encoding="utf-8"))
            raw = np.fromfile(folder / "ch1.bin", dtype=np.uint8)
            t = np.arange(len(raw)) / 2_000_000
            start = .0035 + 19*.0002
            raw[(t >= start+partial_start) & (t < start+50e-6)] = 40
            (folder / "ch1.bin").write_bytes(raw.tobytes())
            meta["CH1"]["sha256"] = hashlib.sha256(raw.tobytes()).hexdigest()
            (folder / "metadata.json").write_text(json.dumps(meta), encoding="utf-8")
            report = review.generate(folder)
            result = json.loads((folder / "evidence/review.json").read_text(encoding="utf-8"))
            self.assertIsNotNone(result["partial_B_pulse"])
            self.assertEqual(result["B_reference_kind"], "partial_pulse_threshold_crossing")
            self.assertGreater(result["primary_latency_from_inferred_B_ms"], 3.7)
            self.assertIn("未丢弃后改用下一完整扫描", report.read_text(encoding="utf-8"))
            self.assertFalse(result["strict_metrological_upper_bound"])

    def test_any_key_and_force_and_conditional_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            fixture(folder)
            report = review.generate(folder)
            result = json.loads((folder / "evidence/review.json").read_text(encoding="utf-8"))
            self.assertTrue(report.is_file())
            self.assertIn("K24", result["trial"])
            self.assertIn("轻力度", result["trial"])
            self.assertFalse(result["strict_metrological_upper_bound"])
            self.assertGreater(result["primary_latency_from_inferred_B_ms"], 3.5)
            self.assertLess(result["primary_latency_from_inferred_B_ms"], 3.65)
            self.assertEqual(len(result["sensitivities"]), 18)
            text = report.read_text(encoding="utf-8")
            self.assertIn("不是严格最坏上界", text)
            # Share the actual page template rather than duplicating its CSS.
            self.assertEqual(text.split("<style>")[1].split("</style>")[0],
                             review.page("", "").split("<style>")[1].split("</style>")[0])
            self.assertIn("完整延迟与模拟起音放大", text)
            self.assertIn("非直接物理闭合", text)
            self.assertIn('name="viewport"', text)
            for name in ("b_detail", "audio_detail"):
                svg = (folder / f"evidence/{name}.svg").read_text(encoding="utf-8")
                for mark in ("起点：推断 B", "终点：模拟起音",
                             f'{result["primary_latency_from_inferred_B_ms"]:.5f} ms'):
                    self.assertIn(mark, svg)

    def test_raw_envelope_keeps_last_partial_bin_and_baseline(self):
        fig, ax = review.plt.subplots()
        values = np.zeros(8803)
        values[-1] = 9
        review.raw_envelope(ax, values, 1e-6, 0, .008803, 0, 1000, baseline=1)
        vertices = np.concatenate([p.vertices for p in ax.collections[0].get_paths()])
        self.assertEqual(vertices[:, 1].max(), 8)
        self.assertEqual(vertices[:, 1].min(), -1)
        review.plt.close(fig)

    def test_no_pulse_widening_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            fixture(folder, widened=False)
            with self.assertRaisesRegex(ValueError, "脉宽变宽"):
                review.generate(folder)
            self.assertFalse((folder / "evidence/report.html").exists())

    def test_hash_mismatch_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            fixture(folder)
            (folder / "ch2.bin").write_bytes(b"modified")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                review.generate(folder)


if __name__ == "__main__":
    unittest.main()

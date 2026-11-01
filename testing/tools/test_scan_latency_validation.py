import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

from scan_latency_validation import (
    generate, read_csv, verify, render_report, measurement_window, main_pulses,
    SignalEvidenceError, common_scope_tail_window, pulses, analyze,
)


class ScanTests(unittest.TestCase):
    def test_initial_contact_chatter_has_exact_rejected_events(self):
        t = np.array([0., .000994, .00099405, .000996, .0009961,
                      .001, .001025, .0012])
        low = np.array([False, True, False, True, False, True, False, False])
        with self.assertRaises(SignalEvidenceError) as raised:
            main_pulses(t, low, "列信号", [.001, .001025])
        error = raised.exception
        self.assertEqual(error.details["rejected_count"], 2)
        self.assertEqual(error.details["total_short_count"], 2)
        self.assertAlmostEqual(error.details["events"][0]["width_us"], .05)
        self.assertAlmostEqual(error.details["events"][0]["relative_to_first_main_us"], -6.)
        self.assertIn("不能据此认定接线错误", str(error))

    def tail_fixture(self, event_time=.03015):
        extra = self.data.copy()
        extra[:, 0] += .02
        data = np.vstack((self.data, extra))
        data[(data[:, 0] >= event_time) & (data[:, 0] < event_time+1.5e-6), 3] = 0
        with self.assertRaises(SignalEvidenceError) as raised:
            main_pulses(data[:, 0], data[:, 3] == 0, "列信号", trim=True)
        sc_s, sc_e = pulses(self.scope_t, self.column < 1.5, trim=True)
        return data, raised.exception, (sc_s, sc_e)

    def test_common_window_only_excludes_late_column_artifact(self):
        data, error, intervals = self.tail_fixture()
        with self.assertRaises(SignalEvidenceError):
            verify(data, self.scope_t, self.column, .0106, 30, 25, 2_000_000,
                   scope_intervals=intervals, first_contact_anchor=True)
        bounded, policy = common_scope_tail_window(
            data, self.scope_t, intervals, 2_000_000, error)
        result = verify(bounded, self.scope_t, self.column, .0106, 30, 25, 2_000_000,
                        scope_intervals=intervals, first_contact_anchor=True)
        self.assertTrue(result["conditional_below_5ms"])
        self.assertAlmostEqual(bounded[-1, 0], self.data[-1, 0]+.001)
        self.assertAlmostEqual(policy["retained_tail_guard_us"], 1000)
        self.assertEqual(policy["excluded_intermediate_events"], error.details["events"])
        self.assertGreater(data[-1, 0], bounded[-1, 0])

    def test_common_window_cannot_hide_in_scope_artifact(self):
        data, error, intervals = self.tail_fixture(.01015)
        with self.assertRaises(SignalEvidenceError):
            common_scope_tail_window(data, self.scope_t, intervals, 2_000_000, error)

    def test_common_window_cannot_hide_guard_artifact(self):
        data, error, intervals = self.tail_fixture(.02015)
        with self.assertRaises(SignalEvidenceError):
            common_scope_tail_window(data, self.scope_t, intervals, 2_000_000, error)

    def short_tail_fixture(self, event_times=(.03015,)):
        extra = self.data.copy()
        extra[:, 0] += .02
        data = np.vstack((self.data, extra))
        for when in event_times:
            data[(data[:, 0] >= when) & (data[:, 0] < when+.5e-6), 3] = 0
        with self.assertRaises(SignalEvidenceError) as raised:
            main_pulses(data[:, 0], data[:, 3] == 0, "列信号", trim=True)
        sc_s, sc_e = pulses(self.scope_t, self.column < 1.5, trim=True)
        return data, raised.exception, (sc_s, sc_e)

    def test_common_window_can_bound_complete_late_short_event_list(self):
        data, error, intervals = self.short_tail_fixture(
            tuple(.03015+i*.0002 for i in range(15)))
        self.assertEqual(len(error.details["events"]), 10)
        bounded, policy = common_scope_tail_window(
            data, self.scope_t, intervals, 2_000_000, error)
        self.assertEqual(len(policy["excluded_short_events"]), 15)
        self.assertEqual(policy["excluded_intermediate_events"], [])
        result = verify(bounded, self.scope_t, self.column, .0106, 30, 25,
                        2_000_000, scope_intervals=intervals, first_contact_anchor=True)
        self.assertAlmostEqual(result["b_window_scope_s"][0], .004025*1.00003+.003)

    def test_common_window_recomputes_shorts_instead_of_trusting_preview(self):
        data, error, intervals = self.short_tail_fixture((.01015, .03015))
        error.details["events"] = error.details["events"][1:]
        with self.assertRaises(SignalEvidenceError):
            common_scope_tail_window(data, self.scope_t, intervals, 2_000_000, error)

    def test_common_window_rejects_incomplete_short_classification(self):
        data, error, intervals = self.short_tail_fixture()
        error.details["rejected_count"] += 1
        with self.assertRaises(SignalEvidenceError):
            common_scope_tail_window(data, self.scope_t, intervals, 2_000_000, error)

    def test_common_window_rejects_wrong_sync(self):
        data, error, (starts, ends) = self.tail_fixture()
        ends = ends.copy()
        ends[5] += 5e-6
        with self.assertRaises(SignalEvidenceError):
            common_scope_tail_window(
                data, self.scope_t, (starts, ends), 2_000_000, error)

    def test_common_window_does_not_handle_row_or_short_errors(self):
        data, error, intervals = self.tail_fixture()
        for category, channel in (("intermediate_pulses", "B 行"),
                                   ("unexplained_short_pulses", "列信号")):
            error.details.update(category=category, channel=channel)
            with self.assertRaises(SignalEvidenceError):
                common_scope_tail_window(data, self.scope_t, intervals, 2_000_000, error)

    def test_analyze_common_window_remains_observation_and_preserves_data(self):
        data, _, _ = self.tail_fixture()
        original = data.copy()
        with tempfile.TemporaryDirectory() as temp:
            csv = Path(temp) / "digital.csv"
            csv.write_bytes(b"original digital evidence")
            with patch("scan_latency_validation.read_csv", return_value=data), \
                    patch("latency_waveforms.load", return_value=(
                        (self.column, np.zeros(len(self.column))), .5e-6,
                        {"raw_sha256": {"CH1": "first", "CH2": "second"},
                         "version_user_recorded": {}})), \
                    patch("latency_waveforms.onsets",
                          return_value=[{"onset_scope_s": .0076}]):
                result, *_ = analyze(
                    Path(temp), csv, ("t", "a", "b", "c"), 0, 0, True,
                    2_000_000, observation_only=True)
            self.assertEqual(result["analysis_model_version"], "digital_rows_v6_common_window")
            self.assertIsNone(result["conditional_below_5ms"])
            self.assertIsNone(result["conditional_upper_ms"])
            self.assertFalse(result["error_budget_verified"])
            self.assertGreater(result["common_recording_window"]["retained_tail_guard_us"], 900)
            self.assertEqual(csv.read_bytes(), b"original digital evidence")
            np.testing.assert_array_equal(data, original)

    def setUp(self):
        self.t = np.arange(40000) * .5e-6
        phase = np.arange(40000) % 400
        a = (phase >= 50).astype(int)
        b = ((phase < 50) | (phase >= 100)).astype(int)
        c = np.ones(len(a), dtype=int)
        c[((self.t >= .002) & (a == 0)) | ((self.t >= .004) & (b == 0))] = 0
        self.data = np.column_stack((self.t, a, b, c))
        self.scope_t = self.t * 1.00003 + .003
        self.column = c * 3.3

    def test_analog_prior_contact_has_own_clock_and_preserves_rejection(self):
        column = self.column.copy()
        column[3640:3644] = 0
        with patch("scan_latency_validation.read_csv", return_value=self.data), \
                patch("latency_waveforms.load",
                      return_value=((column, column), .5e-6, {})):
            with self.assertRaises(SignalEvidenceError) as raised:
                analyze(Path("."), Path("unused.csv"), ("t", "a", "b", "c"),
                        0, 0, True, 2_000_000, observation_only=True)
        detail = raised.exception.details
        self.assertEqual(detail["category"], "prior_analog_column_contact")
        self.assertAlmostEqual(detail["events"][0]["width_us"], 2)
        self.assertAlmostEqual(detail["events"][0]["before_first_main_us"], 180)

    def run_verify(self, data=None, column=None, onset=.0106):
        return verify(self.data if data is None else data, self.scope_t,
                      self.column if column is None else column, onset, 30., 25.)

    def test_valid_and_upper(self):
        result = self.run_verify()
        self.assertTrue(result["conditional_below_5ms"])
        self.assertAlmostEqual(result["scan_period_max_us"], 200, places=5)
        self.assertAlmostEqual(result["alignment_scale"], 1.00003, places=7)
        self.assertGreater(result["conditional_upper_ms"], 3.7)
        self.assertFalse(result["strict_metrological_upper_bound"])

    def test_fixed_window_excludes_remote_prefix_but_not_nearby_glitches(self):
        data = self.data.copy()
        data[:, 0] += 1.
        prefix = np.array([[0., 1, 1, 1], [.1, 0, 1, 1],
                           [.10000005, 1, 1, 1]])
        data = np.vstack((prefix, data))
        cropped, policy = measurement_window(data)
        self.assertAlmostEqual(cropped[0, 0], .997)
        self.assertGreater(policy["excluded_duration_s"], .99)
        result = verify(cropped, self.scope_t, self.column, .0106, 30, 25,
                        2_000_000, first_contact_anchor=True)
        self.assertTrue(result["conditional_below_5ms"])
        # An unbounded in-window artifact remains an error.
        nearby = np.array([[1.0011, 0, 1, 1], [1.00110005, 1, 1, 1]])
        nearby = np.vstack((data, nearby))
        nearby = nearby[np.argsort(nearby[:, 0])]
        cropped, _ = measurement_window(nearby)
        with self.assertRaises(ValueError):
            verify(cropped, self.scope_t, self.column, .0106, 30, 25,
                   2_000_000, first_contact_anchor=True)

    def test_window_cannot_hide_earlier_substantive_column_contact(self):
        data = self.data.copy()
        data[:, 0] += 1.
        prefix = np.array([[0., 1, 1, 1], [.1, 1, 1, 0],
                           [.100002, 1, 1, 1]])
        with self.assertRaisesRegex(ValueError, "超过 1"):
            measurement_window(np.vstack((prefix, data)))

    def test_prior_contact_error_distinguishes_high_origin_and_keeps_event_times(self):
        data = self.data.copy()
        mask = (data[:, 0] >= .00181) & (data[:, 0] < .0018115)
        data[mask, 3] = 0
        data[:, 0] += 1.
        data = np.vstack((np.array([[0., 1, 1, 1]]), data))
        with self.assertRaises(SignalEvidenceError) as raised:
            measurement_window(data)
        detail = raised.exception.details
        self.assertEqual(detail["category"], "prior_column_contact")
        self.assertFalse(detail["initial_column_low"])
        self.assertAlmostEqual(detail["events"][0]["before_first_main_us"], 190.)
        self.assertAlmostEqual(detail["events"][0]["width_us"], 1.5)
        self.assertIn("不等于记录开头为低", str(raised.exception))

    def startup_prefix_fixture(self):
        data = self.data.copy()
        data[:, 0] += 1.
        prefix = np.array([[0., 1, 0, 0], [.000014, 1, 1, 1],
                           [.0000141, 1, 1, 0], [.0000145, 1, 1, 1]])
        return np.vstack((prefix, data))

    def test_initial_low_prefix_is_bounded_and_keeps_fixed_window(self):
        data = self.startup_prefix_fixture()
        before = data.copy()
        with self.assertRaisesRegex(ValueError, "起始列低"):
            measurement_window(data)
        cropped, policy = measurement_window(data, allow_initial_prefix=True)
        self.assertAlmostEqual(cropped[0, 0], .997)
        prefix = policy["initial_low_prefix"]
        self.assertAlmostEqual(prefix["end_s"], .0000145)
        self.assertGreater(prefix["quiet_until_first_main_s"], 1.)
        np.testing.assert_array_equal(data, before)

    def test_initial_low_prefix_cannot_hide_later_contact(self):
        data = self.startup_prefix_fixture()
        for changes in (np.array([[.1, 1, 1, 0], [.100002, 1, 1, 1]]),
                        np.array([[.1, 1, 1, 0], [.1000005, 1, 1, 1]])):
            changed = np.vstack((data, changes))
            changed = changed[np.argsort(changed[:, 0])]
            with self.assertRaises(ValueError):
                measurement_window(changed, allow_initial_prefix=True)

    def test_initial_low_prefix_requires_separation(self):
        data = self.startup_prefix_fixture()
        data[data[:, 0] >= 1., 0] -= .994
        with self.assertRaises(ValueError):
            measurement_window(data, allow_initial_prefix=True)

    def test_initial_low_prefix_rejects_long_initial_low(self):
        data = self.startup_prefix_fixture()
        data[1:4, 0] += .0003
        with self.assertRaises(ValueError):
            measurement_window(data, allow_initial_prefix=True)

    def test_initial_low_prefix_requires_both_row_periods(self):
        data = self.startup_prefix_fixture()
        data[:, 2] = 1
        with self.assertRaisesRegex(ValueError, "独立行扫描"):
            measurement_window(data, allow_initial_prefix=True)

    def test_analyze_initial_prefix_remains_observation_and_preserves_data(self):
        data = self.startup_prefix_fixture()
        before = data.copy()
        with tempfile.TemporaryDirectory() as temp:
            csv = Path(temp) / "digital.csv"
            csv.write_bytes(b"original startup evidence")
            with patch("scan_latency_validation.read_csv", return_value=data), \
                    patch("latency_waveforms.load", return_value=(
                        (self.column, np.zeros(len(self.column))), .5e-6,
                        {"raw_sha256": {"CH1": "first", "CH2": "second"},
                         "version_user_recorded": {}})), \
                    patch("latency_waveforms.onsets",
                          return_value=[{"onset_scope_s": .0076}]):
                result, *_ = analyze(Path(temp), csv, ("t", "a", "b", "c"),
                                     0, 0, True, 2_000_000, observation_only=True)
            self.assertEqual(result["analysis_model_version"], "digital_rows_v8_bounded_recording")
            self.assertIsNone(result["conditional_below_5ms"])
            self.assertFalse(result["error_budget_verified"])
            self.assertIn("scope_record_start_logic_s", result["measurement_window"]["initial_low_prefix"])
            self.assertEqual(csv.read_bytes(), b"original startup evidence")
            np.testing.assert_array_equal(data, before)

    def test_slow_not_pass(self):
        self.assertFalse(self.run_verify(onset=.013)["conditional_below_5ms"])

    def test_sparse_export_uses_capture_rate_not_event_gap(self):
        changes = np.r_[True, np.any(np.diff(self.data[:, 1:], axis=0) != 0, axis=1)]
        changes[-1] = True
        sparse = self.data[changes]
        with self.assertRaises(ValueError):
            self.run_verify(data=sparse)
        result = verify(sparse, self.scope_t, self.column, .0106, 30, 25, 2_000_000)
        self.assertTrue(result["conditional_below_5ms"])
        self.assertEqual(result["digital_resolution_us"], .5)

    def test_swapped_rows_rejected(self):
        data = self.data[:, [0, 2, 1, 3]]
        with self.assertRaises(ValueError):
            self.run_verify(data=data)

    def test_mismatched_record_rejected(self):
        column = self.column.copy()
        column[6000:6100] = 3.3
        with self.assertRaises(ValueError):
            self.run_verify(column=column)

    def test_scan_pause_rejected(self):
        data = self.data.copy()
        data[10000:10400, 2] = 1
        with self.assertRaises(ValueError):
            self.run_verify(data=data)

    def test_clipped_column_rejected(self):
        data = self.data[4100:]
        with self.assertRaises(ValueError):
            self.run_verify(data=data)

    def test_first_contact_anchor_supports_zero_to_three_single_pulses(self):
        for count in range(4):
            with self.subTest(count=count):
                data = self.data.copy()
                t, a, b, _ = data.T
                c = np.ones(len(t), dtype=int)
                c[((t >= .002) & (a == 0)) |
                  ((t >= .002+count*.0002) & (b == 0))] = 0
                data[:, 3] = c
                result = verify(data, self.scope_t, c*3.3, .009, 30, 25,
                                first_contact_anchor=True)
                self.assertAlmostEqual(result["b_window_scope_s"][0],
                                       (.002025+count*.0002)*1.00003+.003, places=8)
                self.assertTrue(result["alignment_first_contact_anchor"])
                self.assertTrue(all(v["conflicts_with_observed_prepress_quiet"]
                                    for v in result["alignment_rejected_shift_candidates"]))

    def test_anchor_still_rejects_missing_b_and_mismatched_column(self):
        missing = self.data.copy()
        missing[:, 2] = 1
        with self.assertRaisesRegex(ValueError, "A/B 扫描周期不足"):
            verify(missing, self.scope_t, self.column, .0106, 30, 25,
                   first_contact_anchor=True)
        column = self.column.copy()
        column[6000:6100] = 3.3
        with self.assertRaises(ValueError):
            verify(self.data, self.scope_t, column, .0106, 30, 25,
                   first_contact_anchor=True)

    def test_anchor_cannot_replace_prepress_quiet(self):
        data = self.data[3900:]
        with self.assertRaisesRegex(ValueError, "静止段不足"):
            verify(data, self.scope_t, self.column, .0106, 30, 25,
                   first_contact_anchor=True)

    def test_csv_mapping_validation(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "logic.csv"
            path.write_text("t,a,b,c\n" + "".join(
                f"{t},1,1,1\n" for t in np.arange(100)*1e-7), encoding="utf-8")
            self.assertEqual(read_csv(path, ("t", "a", "b", "c")).shape, (100, 4))
            with self.assertRaises(ValueError):
                read_csv(path, ("t", "a", "a", "c"))

    def test_full_report_and_import_preserved(self):
        import csv
        import json
        from test_review_latency_evidence import fixture
        with tempfile.TemporaryDirectory() as folder:
            trial = Path(folder)
            fixture(trial)
            count = 40000
            t = np.arange(count) / 2e6
            phase = (np.arange(count) - 7002) % 400
            a = (phase >= 50).astype(int)
            b = ((phase < 50) | (phase >= 100)).astype(int)
            c = (np.fromfile(trial / "ch1.bin", dtype=np.uint8) > 70).astype(int)
            source = trial / "export.csv"
            with source.open("w", newline="", encoding="utf-8") as out:
                writer = csv.writer(out)
                writer.writerow(("t", "a", "b", "c"))
                writer.writerows(zip(t, a, b, c))
            with self.assertRaises(ValueError):
                generate(trial, source, ("t", "a", "b", "c"), 30, 25)
            before = {name: (trial / name).read_bytes()
                      for name in ("ch1.bin", "ch2.bin", "metadata.json", "trial.json")}
            report = generate(trial, source, ("t", "a", "b", "c"), 30, 25, True)
            self.assertTrue(report.is_file())
            self.assertEqual((report.parent / "logic.csv").read_bytes(), source.read_bytes())
            result = json.loads((report.parent / "analysis.json").read_text(encoding="utf-8"))
            self.assertTrue(result["conditional_below_5ms"])
            self.assertTrue((report.parent / "b_window.png").is_file())
            text = report.read_text(encoding="utf-8")
            from polyphony_acceptance.acceptance_reports import page
            self.assertEqual(text.split("<style>")[1].split("</style>")[0],
                             page("", "").split("<style>")[1].split("</style>")[0])
            for expected in ("不是严格计量上界", "逻辑分析仪：B 扫描窗口证据",
                             "示波器：联合时间轴上的模拟起音", "最晚起音判据",
                             "两个间隔不能直接混用", 'name="viewport"'):
                self.assertIn(expected, text)
            delay = (result["audio_latest_scope_s"]-result["b_window_scope_s"][0])*1000
            for name in ("b_window", "joint_audio"):
                self.assertTrue((report.parent / f"{name}.png").is_file())
                svg = (report.parent / f"{name}.svg").read_text(encoding="utf-8")
                for expected in ("首次 B 扫描窗口起点", "非物理闭合瞬间",
                                 "最晚模拟起音", f"{delay:.5f} ms"):
                    self.assertIn(expected, svg)
            audio_svg = (report.parent / "joint_audio.svg").read_text(encoding="utf-8")
            self.assertIn("起音局部放大", audio_svg)
            self.assertIn("不占用波形电压轴", audio_svg)
            # Re-rendering must not alter results, digital CSV or raw records.
            analysis = (report.parent / "analysis.json").read_bytes()
            evidence = result["audio_evidence"]
            self.assertFalse((trial / "evidence/review.json").exists())
            self.assertFalse(result["scope_only_B_inference_required"])
            raw2 = np.fromfile(trial / "ch2.bin", dtype=np.uint8)
            render_report(report.parent, trial, np.column_stack((t, a, b, c)), result,
                          evidence, (raw2.astype(float)-127)*.002, 1/2e6, .0035)
            self.assertEqual((report.parent / "analysis.json").read_bytes(), analysis)
            self.assertEqual((report.parent / "logic.csv").read_bytes(), source.read_bytes())
            self.assertEqual(result, json.loads(analysis))
            for name, data in before.items():
                self.assertEqual((trial / name).read_bytes(), data)
            observe = generate(trial, source, ("t", "a", "b", "c"), 0, 0, True,
                               2_000_000, observation_only=True)
            unbudgeted = json.loads((observe.parent / "analysis.json").read_text(encoding="utf-8"))
            self.assertIsNone(unbudgeted["conditional_below_5ms"])
            self.assertIsNone(unbudgeted["conditional_upper_ms"])
            self.assertIn("不作达标判定", observe.read_text(encoding="utf-8"))
            self.assertIn("结论边界", observe.read_text(encoding="utf-8"))
            self.assertIn("不自动套用历史批次余量", observe.read_text(encoding="utf-8"))
            self.assertNotIn("待完成 24 键", observe.read_text(encoding="utf-8"))
            self.assertNotIn("暂定的 100 µs", observe.read_text(encoding="utf-8"))
            self.assertIn("不是校准确认的误差上限", observe.read_text(encoding="utf-8"))
            self.assertNotIn("条件性上界小于 5 ms", observe.read_text(encoding="utf-8"))

    def test_full_generation_does_not_require_column_only_review(self):
        import csv
        import hashlib
        import json
        from test_review_latency_evidence import fixture
        for count in (0, 1, 3):
            with self.subTest(count=count), tempfile.TemporaryDirectory() as temp:
                trial = Path(temp)
                fixture(trial)
                t = np.arange(40000)/2e6
                phase = (np.arange(40000)-7002) % 400
                a = (phase >= 50).astype(int)
                b = ((phase < 50) | (phase >= 100)).astype(int)
                c = np.ones(len(t), dtype=int)
                c[((t >= .003501) & (a == 0)) |
                  ((t >= .003501+count*.0002) & (b == 0))] = 0
                ch1 = np.where(c, 122, 40).astype(np.uint8)
                onset = .003501+count*.0002+.000025+.00355
                y = np.where(t >= onset, .1*np.sin(2*np.pi*1000*(t-onset)), 0)
                ch2 = np.rint(y/.002+127).astype(np.uint8)
                meta = json.loads((trial/"metadata.json").read_text(encoding="utf-8"))
                for ch, raw in ((1, ch1), (2, ch2)):
                    (trial/f"ch{ch}.bin").write_bytes(raw.tobytes())
                    meta[f"CH{ch}"]["sha256"] = hashlib.sha256(raw.tobytes()).hexdigest()
                (trial/"metadata.json").write_text(json.dumps(meta), encoding="utf-8")
                source = trial/"digital.csv"
                with source.open("w", newline="", encoding="utf-8") as out:
                    writer = csv.writer(out)
                    writer.writerow(("t", "a", "b", "c"))
                    writer.writerows(zip(t, a, b, c))
                before = {name: (trial/name).read_bytes() for name in
                          ("ch1.bin", "ch2.bin", "metadata.json", "trial.json")}
                with patch("review_latency_evidence.generate",
                           side_effect=AssertionError("Column-only B inference must not run")):
                    report = generate(trial, source, ("t", "a", "b", "c"), 0, 0,
                                      True, 2_000_000, observation_only=True)
                result = json.loads(report.with_name("analysis.json").read_text(encoding="utf-8"))
                self.assertIsNone(result["conditional_below_5ms"])
                self.assertEqual(result["analysis_model_version"], "digital_rows_v5")
                self.assertEqual(len(result["audio_evidence"]["sensitivities"]), 18)
                self.assertIn("不要求 5 个", report.read_text(encoding="utf-8"))
                self.assertNotIn("../../evidence/report.html", report.read_text(encoding="utf-8"))
                for name, raw in before.items():
                    self.assertEqual((trial/name).read_bytes(), raw)
                # A changed RAW file must not be silently reinterpreted.
                damaged = bytearray(before["ch2.bin"])
                damaged[0] ^= 1
                (trial/"ch2.bin").write_bytes(damaged)
                with self.assertRaisesRegex(ValueError, "哈希或长度"):
                    generate(trial, source, ("t", "a", "b", "c"), 0, 0,
                             True, 2_000_000, observation_only=True)


class BoundaryTests(unittest.TestCase):
    def setUp(self):
        ticks = np.arange(240000)
        self.t = ticks / 24e6
        phase = ticks % 4800
        a = np.where(phase < 624, 0, 1)
        b = np.where((phase >= 600) & (phase < 1224), 0, 1)
        c = np.ones(len(ticks), dtype=int)
        c[(self.t >= .002) & (a == 0)] = 0
        c[(self.t >= .004) & (b == 0)] = 0
        self.data = np.column_stack((self.t, a, b, c))
        self.scope_t = self.t * 1.00003 + .003
        self.column = c * 3.3
        self.phase = phase

    def run_verify(self, data=None):
        return verify(self.data if data is None else data, self.scope_t,
                      self.column, .0106, 30, 25, 24_000_000)

    def test_bounded_overlap_and_edge_glitches_keep_real_b_window(self):
        data = self.data.copy()
        data[self.phase == 626, 1] = 0
        data[self.phase == 1226, 2] = 0
        data[(self.t >= .002) & (self.t < .004) & (self.phase == 626), 3] = 0
        data[(self.t >= .004) & (self.phase == 1226), 3] = 0
        result = self.run_verify(data)
        self.assertTrue(result["conditional_below_5ms"])
        self.assertAlmostEqual(result["b_window_scope_s"][0], .004025*1.00003+.003, places=8)
        self.assertGreater(result["boundary_additional_margin_us"], 4)
        self.assertAlmostEqual(result["ab_boundary_delta_min_us"], -1, places=5)
        for count in result["excluded_short_low_pulses"].values():
            self.assertGreater(count, 0)
        self.assertEqual(len(result["alignment_rejected_shift_candidates"]), 4)

    def test_far_glitch_rejected(self):
        data = self.data.copy()
        data[self.phase == 2500, 1] = 0
        with self.assertRaisesRegex(ValueError, "远离"):
            self.run_verify(data)

    def test_bounded_prefix_short_transition_excluded_and_recorded(self):
        data = self.data.copy()
        # Shift full scans later and prepend a short simultaneous startup event.
        data[:, 0] += .0003
        prefix = np.array([[0, 1, 1, 1], [.000085, 0, 1, 0],
                           [.0000853, 1, 1, 1]])
        data = np.vstack((prefix, data))
        result = self.run_verify(data)
        self.assertAlmostEqual(result["startup_prefix"]["excluded_duration_us"], 300)
        self.assertEqual(result["startup_prefix"]["excluded_short_low_pulses"]["A"], 1)
        self.assertTrue(result["conditional_below_5ms"])

    def test_long_prefix_low_cannot_be_hidden(self):
        data = self.data.copy()
        data[:, 0] += .0003
        prefix = np.array([[0, 1, 1, 1], [.000085, 0, 1, 0],
                           [.00009, 1, 1, 1]])
        with self.assertRaisesRegex(ValueError, "前导段"):
            self.run_verify(np.vstack((prefix, data)))

    def startup_frame(self, column_low=False, late=False):
        data = self.data.copy()
        data[:, 0] += .000277
        prefix = np.array([
            [0, 1, 1, 1],
            [.000064458, 0, 1, int(not column_low)],
            [.000102083, 0, 0, int(not column_low)],
            [.000103083, 1, 0, 1],
            [.000128, 1, 1, 1]])
        if late:
            data[:, 0] += .001
        return np.vstack((prefix, data))

    def test_anomalous_first_frame_is_audited_not_counted_as_measurement(self):
        result = self.run_verify(self.startup_frame())
        startup = result["startup_prefix"]
        self.assertAlmostEqual(startup["excluded_duration_us"], 277)
        self.assertAlmostEqual(startup["excluded_pulses"]["A"][0]["width_us"], 38.625)
        self.assertTrue(result["conditional_below_5ms"])

    def test_first_frame_with_column_contact_not_discarded(self):
        with self.assertRaisesRegex(ValueError, "列导通"):
            self.run_verify(self.startup_frame(column_low=True))

    def test_startup_disruption_later_than_limit_rejected(self):
        with self.assertRaisesRegex(ValueError, "前导段"):
            self.run_verify(self.startup_frame(late=True))

    def test_intermediate_pulses_not_filtered(self):
        data = self.data.copy()
        data[(self.phase >= 2500) & (self.phase < 2550), 1] = 0
        with self.assertRaisesRegex(ValueError, "非主脉冲"):
            self.run_verify(data)

    def test_wide_overlap_rejected(self):
        data = self.data.copy()
        data[(self.phase >= 624) & (self.phase < 672), 1] = 0
        with self.assertRaises(ValueError):
            self.run_verify(data)

    def test_false_early_b_in_logic_still_fails_full_edge_alignment(self):
        data = self.data.copy()
        data[(self.t >= .0038) & (self.t < .004) & (data[:, 2] == 0), 3] = 0
        with self.assertRaisesRegex(ValueError, "全起止沿"):
            self.run_verify(data)

    def test_sparse_core_uses_intervals_not_only_events(self):
        changes = np.r_[True, np.any(np.diff(self.data[:, 1:], axis=0) != 0, axis=1)]
        changes[-1] = True
        result = self.run_verify(self.data[changes])
        self.assertAlmostEqual(result["b_window_scope_s"][0], .004025*1.00003+.003, places=8)

    def test_missing_a_scan_is_not_filtered(self):
        data = self.data.copy()
        data[(self.t >= .005) & (self.t < .0052), 1] = 1
        with self.assertRaisesRegex(ValueError, "主扫描周期异常"):
            self.run_verify(data)

    def test_trailing_cut_logic_pulse_only_allowed_after_full_scope_coverage(self):
        data = self.data.copy()
        # Extend the logic record beyond the scope, cutting a later held pulse.
        extra = data[:20].copy()
        extra[:, 0] += .01
        extra[:, 3] = 0
        data = np.vstack((data, extra))
        result = self.run_verify(data)
        self.assertTrue(result["logic_trailing_incomplete_pulse_omitted"])
        # Cutting during the actual scope record cannot silently pass.
        with self.assertRaises(ValueError):
            self.run_verify(data[:200000])

    def test_partial_b_interior_rejected_even_when_instruments_agree(self):
        data = self.data.copy()
        # First sustained B pulse starts midway through its row.
        mask = (self.t >= .004025) & (self.t < .004035)
        data[mask, 3] = 1
        column = data[:, 3]*3.3
        with self.assertRaisesRegex(SignalEvidenceError, "内部列信号只部分") as raised:
            verify(data, self.scope_t, column, .0106, 30, 25, 24_000_000)
        detail = raised.exception.details
        self.assertEqual(detail["category"], "partial_b_window")
        self.assertAlmostEqual(detail["column_onset_from_b_start_us"], 10)
        self.assertTrue(detail["column_low_reaches_core_end"])

    def test_slowly_varying_width_does_not_prove_unique_sync(self):
        data = self.data.copy()
        cycles = np.arange(len(data)) // 4800
        widths = 600 + cycles*12
        data[:, 3] = np.where((self.t >= .002) & (self.phase < widths), 0, 1)
        with self.assertRaisesRegex(ValueError, "无法唯一确定同步"):
            verify(data, self.scope_t, data[:, 3]*3.3, .0106, 30, 25, 24_000_000)


class InitialATransientTests(unittest.TestCase):
    def setUp(self):
        BoundaryTests.setUp(self)
        initial = (self.t >= .002) & (self.t < .002008)
        self.data[initial, 3] = 1
        for start, end in ((.002004, .0020042), (.002005, .0020052)):
            self.data[(self.t >= start) & (self.t < end), 3] = 0
        self.column[(self.t >= .002) & (self.t < .002004)] = 3.3

    def verify(self, data=None, column=None, anchor=True):
        return verify(self.data if data is None else data, self.scope_t,
                      self.column if column is None else column,
                      .0106, 0, 0, 24_000_000, first_contact_anchor=anchor)

    def test_a_only_transient_keeps_b_start_and_later_sync_edges(self):
        result = self.verify()
        contact = result["initial_a_contact_transient"]
        self.assertEqual(len(contact["events"]), 2)
        self.assertTrue(contact["following_b_core_column_high"])
        self.assertEqual(contact["excluded_exact_sync_edges"], 1)
        self.assertAlmostEqual(contact["first_start_difference_us"], -4.00012, places=5)
        self.assertAlmostEqual(result["b_window_scope_s"][0], .004025*1.00003+.003)
        self.assertAlmostEqual(result["alignment_scale"], 1.00003, places=8)
        self.assertLess(result["alignment_max_residual_us"], .001)
        self.assertEqual(result["excluded_short_low_pulses"]["column"], 0)

    def test_sparse_transient_uses_preceding_core_state(self):
        changes = np.r_[True, np.any(np.diff(self.data[:, 1:], axis=0) != 0, axis=1)]
        changes[-1] = True
        result = self.verify(data=self.data[changes])
        self.assertIsNotNone(result["initial_a_contact_transient"])

    def test_without_same_press_anchor_still_rejected(self):
        with self.assertRaises(SignalEvidenceError):
            self.verify(anchor=False)

    def test_first_scope_fall_outside_a_window_rejected(self):
        column = self.column.copy()
        column[(self.t >= .00199) & (self.t < .002004)] = 0
        with self.assertRaisesRegex(ValueError, "独占窗口"):
            self.verify(column=column)

    def test_earlier_raw_scope_short_low_cannot_be_hidden(self):
        column = self.column.copy()
        column[(self.t >= .0019) & (self.t < .0019002)] = 0
        with self.assertRaisesRegex(ValueError, "窗口外低段"):
            self.verify(column=column)

    def test_first_rising_edge_still_strict(self):
        column = self.column.copy()
        column[(self.t >= .002026) & (self.t < .002031)] = 0
        with self.assertRaisesRegex(ValueError, "全起止沿"):
            self.verify(column=column)

    def test_later_edges_still_strict(self):
        column = self.column.copy()
        column[(self.t >= .006) & (self.t < .00601)] = 3.3
        with self.assertRaisesRegex(ValueError, "全起止沿"):
            self.verify(column=column)

    def test_b_short_low_is_not_an_a_transient(self):
        data = self.data.copy()
        data[(self.t >= .002034) & (self.t < .0020342), 3] = 0
        with self.assertRaises(SignalEvidenceError):
            self.verify(data=data)

    def test_short_low_in_another_a_window_is_not_classified(self):
        data = self.data.copy()
        data[(self.t >= .001804) & (self.t < .0018042), 3] = 0
        with self.assertRaises(SignalEvidenceError):
            self.verify(data=data)

    def test_later_off_window_short_low_is_not_classified(self):
        data = self.data.copy()
        data[(self.t >= .00219) & (self.t < .0021902), 3] = 0
        with self.assertRaises(SignalEvidenceError):
            self.verify(data=data)

    def test_initial_intermediate_pulse_remains_rejected(self):
        data = self.data.copy()
        data[(self.t >= .002004) & (self.t < .0020055), 3] = 0
        with self.assertRaisesRegex(ValueError, "非主脉冲"):
            self.verify(data=data)

    def test_a_transient_can_coexist_with_supported_b_midwindow(self):
        data = self.data.copy()
        column = self.column.copy()
        mask = (self.t >= .004025) & (self.t < .004035)
        data[mask, 3] = 1
        column[mask] = 3.3
        result = self.verify(data=data, column=column)
        self.assertIsNotNone(result["initial_a_contact_transient"])
        self.assertEqual(result["b_onset_model"], "midwindow_b_v1")


class MidwindowBTests(unittest.TestCase):
    def setUp(self):
        BoundaryTests.setUp(self)
        mask = (self.t >= .004025) & (self.t < .004035)
        self.data[mask, 3] = 1
        self.column = self.data[:, 3]*3.3

    def verify(self, data=None, column=None, anchor=True):
        from scope_column_pulses import extract
        column = self.column if column is None else column
        dt = self.scope_t[1]-self.scope_t[0]
        s, e, _ = extract(column, dt)
        return verify(self.data if data is None else data, self.scope_t, column,
                      .0106, 30, 25, 24_000_000,
                      scope_intervals=(s*dt+self.scope_t[0], e*dt+self.scope_t[0]),
                      first_contact_anchor=anchor)

    def test_supported_partial_preserves_first_window_and_conservative_margin(self):
        result = self.verify()
        event = result["b_midwindow_contact"]
        self.assertEqual(result["b_onset_model"], "midwindow_b_v1")
        self.assertAlmostEqual(result["b_window_scope_s"][0], .004025*1.00003+.003)
        self.assertAlmostEqual(result["conditional_closure_earliest_scope_s"], .003825*1.00003+.003)
        self.assertAlmostEqual(event["column_onset_from_b_start_us"], 10.)
        self.assertEqual(len(event["following_full_b_windows_logic_s"]), 3)
        self.assertEqual(event["raw_digital_core_low_segments"], 1)
        self.assertTrue(event["first_partial_window_preserved"])
        self.assertGreater(result["maximum_scan_allowance_us"], 225.)

    def test_sparse_csv_uses_full_intervals(self):
        changes = np.r_[True, np.any(np.diff(self.data[:, 1:], axis=0) != 0, axis=1)]
        changes[-1] = True
        self.assertEqual(self.verify(data=self.data[changes])["b_onset_model"], "midwindow_b_v1")

    def test_without_same_press_confirmation_rejected(self):
        with self.assertRaisesRegex(SignalEvidenceError, "只部分"):
            self.verify(anchor=False)

    def test_a_tail_alone_does_not_become_b_contact(self):
        data = self.data.copy()
        data[(self.t >= .004) & (data[:, 1] != 0), 3] = 1
        with self.assertRaises(ValueError):
            self.verify(data=data, column=data[:, 3]*3.3)

    def test_reopening_in_first_b_core_rejected(self):
        data = self.data.copy()
        data[(self.t >= .004025) & (self.t < .004035), 3] = 0
        data[(self.t >= .004035) & (self.t < .00404), 3] = 1
        with self.assertRaisesRegex(SignalEvidenceError, "只部分"):
            self.verify(data=data, column=data[:, 3]*3.3)

    def test_initial_low_not_reaching_b_tail_rejected(self):
        data = self.data.copy()
        data[(self.t >= .004047) & (self.t < .004051), 3] = 1
        with self.assertRaises(ValueError):
            self.verify(data=data, column=data[:, 3]*3.3)

    def test_later_partial_b_cannot_restart_onset(self):
        data = self.data.copy()
        data[(self.t >= .004225) & (self.t < .004235), 3] = 1
        with self.assertRaisesRegex(SignalEvidenceError, "只部分"):
            self.verify(data=data, column=data[:, 3]*3.3)

    def test_missing_following_full_window_rejected(self):
        data = self.data.copy()
        data[(self.t >= .004225) & (self.t < .004251), 3] = 1
        with self.assertRaisesRegex(ValueError, "三个完整 B"):
            self.verify(data=data, column=data[:, 3]*3.3)

    def test_insufficient_independent_scope_high_witness_rejected(self):
        data = self.data.copy()
        data[(self.t >= .004028) & (self.t < .004035), 3] = 0
        with self.assertRaisesRegex(SignalEvidenceError, "只部分"):
            self.verify(data=data, column=data[:, 3]*3.3)

    def test_raw_scope_low_in_high_witness_not_hidden_by_closing(self):
        column = self.column.copy()
        column[(self.t >= .00403) & (self.t < .0040302)] = 0
        with self.assertRaisesRegex(SignalEvidenceError, "只部分"):
            self.verify(column=column)

    def test_raw_scope_high_in_low_tail_not_hidden_by_closing(self):
        column = self.column.copy()
        column[(self.t >= .004041) & (self.t < .0040412)] = 3.3
        with self.assertRaisesRegex(SignalEvidenceError, "只部分"):
            self.verify(column=column)

    def test_wrong_csv_is_still_rejected_before_partial_model(self):
        data = self.data.copy()
        data[(self.t >= .004035) & (self.t < .00404), 3] = 1
        with self.assertRaisesRegex(ValueError, "全起止沿"):
            self.verify(data=data)


class FragmentedBTests(unittest.TestCase):
    def combined_tail(self, event=.03015):
        extra = self.data.copy()
        extra[:, 0] += .02
        data = np.vstack((self.data, extra))
        data[(data[:, 0] >= event) & (data[:, 0] < event+1.5e-6), 3] = 0
        from scope_column_pulses import extract
        dt = self.scope_t[1]-self.scope_t[0]
        s, e, _ = extract(self.column, dt)
        intervals = (s*dt+self.scope_t[0], e*dt+self.scope_t[0])
        with self.assertRaises(SignalEvidenceError) as raised:
            main_pulses(data[:, 0], data[:, 3] == 0, "列信号", trim=True)
        return data, intervals, raised.exception

    def test_first_b_fragment_and_late_tail_compose_without_moving_b(self):
        data, intervals, error = self.combined_tail()
        original = data.copy()
        bounded, policy = common_scope_tail_window(
            data, self.scope_t, intervals, 24_000_000, error,
            allow_fragmented_initial_b=True)
        self.assertEqual(len(policy["excluded_intermediate_events"]), 1)
        self.assertIsNotNone(policy["prefit_initial_b_fragment"])
        result = verify(
            bounded, self.scope_t, self.column, .0106, 30, 25, 24_000_000,
            scope_intervals=intervals, first_contact_anchor=True,
            allow_fragmented_initial_b=True)
        self.assertAlmostEqual(result["b_window_scope_s"][0],
                               self.verify()["b_window_scope_s"][0])
        np.testing.assert_array_equal(data, original)

    def test_composite_tail_cannot_hide_in_scope_intermediate(self):
        data, intervals, error = self.combined_tail(.00615)
        with self.assertRaises(SignalEvidenceError):
            common_scope_tail_window(
                data, self.scope_t, intervals, 24_000_000, error,
                allow_fragmented_initial_b=True)

    def test_composite_tail_does_not_relax_synchronization(self):
        data, (starts, ends), error = self.combined_tail()
        ends = ends.copy()
        ends[10] += 5e-6
        with self.assertRaises(SignalEvidenceError):
            common_scope_tail_window(
                data, self.scope_t, (starts, ends), 24_000_000, error,
                allow_fragmented_initial_b=True)

    def test_composite_tail_prefit_does_not_replace_analog_witness(self):
        data, intervals, error = self.combined_tail()
        bounded, _ = common_scope_tail_window(
            data, self.scope_t, intervals, 24_000_000, error,
            allow_fragmented_initial_b=True)
        column = self.column.copy()
        column[(self.t >= .004028) & (self.t < .004031)] = 3.3
        with self.assertRaisesRegex(ValueError, "模拟列高段"):
            verify(bounded, self.scope_t, column, .0106, 30, 25, 24_000_000,
                   scope_intervals=intervals, first_contact_anchor=True,
                   allow_fragmented_initial_b=True)

    def setUp(self):
        BoundaryTests.setUp(self)
        for start, end in ((.004026, .004028), (.0040295, .004031),
                           (.0040315, .004034)):
            self.data[(self.t >= start) & (self.t < end), 3] = 1
        self.original = self.data.copy()

    def verify(self, data=None, column=None, enabled=True, anchor=True):
        from scope_column_pulses import extract
        column = self.column if column is None else column
        dt = self.scope_t[1]-self.scope_t[0]
        s, e, _ = extract(column, dt)
        return verify(self.data if data is None else data, self.scope_t, column,
                      .0106, 30, 25, 24_000_000,
                      scope_intervals=(s*dt+self.scope_t[0], e*dt+self.scope_t[0]),
                      first_contact_anchor=anchor, allow_fragmented_initial_b=enabled)

    def test_preserves_first_window_and_raw_fragments(self):
        result = self.verify()
        event = result["b_midwindow_contact"]
        self.assertEqual(event["model"], "initial_b_fragment_interval_v1")
        self.assertEqual(len(event["raw_low_segments"]), 4)
        self.assertEqual(event["excluded_internal_sync_edges"], 6)
        self.assertAlmostEqual(result["b_window_scope_s"][0], .004025*1.00003+.003)
        self.assertAlmostEqual(result["conditional_closure_earliest_scope_s"], .003825*1.00003+.003)
        self.assertEqual(result["excluded_short_low_pulses"]["column"], 0)
        np.testing.assert_array_equal(self.data, self.original)

    def test_analyze_fallback_preserves_evidence_and_unverified_budget(self):
        with tempfile.TemporaryDirectory() as temp:
            csv = Path(temp) / "digital.csv"
            csv.write_bytes(b"unchanged fragmented contact evidence")
            with patch("scan_latency_validation.read_csv", return_value=self.data), \
                    patch("latency_waveforms.load", return_value=(
                        (self.column, np.zeros(len(self.column))), 1.00003/24e6,
                        {"raw_sha256": {"CH1": "first", "CH2": "second"},
                         "version_user_recorded": {}})), \
                    patch("latency_waveforms.onsets",
                          return_value=[{"onset_scope_s": .0076}]):
                result, *_ = analyze(Path(temp), csv, ("t", "a", "b", "c"),
                                     0, 0, True, 24_000_000, observation_only=True)
            self.assertEqual(result["analysis_model_version"], "digital_rows_v7_initial_b_interval")
            self.assertIsNone(result["conditional_below_5ms"])
            self.assertIsNone(result["conditional_upper_ms"])
            self.assertFalse(result["error_budget_verified"])
            self.assertIn("内部原始片段", result["alignment_anchor_assumptions"])
            self.assertEqual(csv.read_bytes(), b"unchanged fragmented contact evidence")
            np.testing.assert_array_equal(self.data, self.original)

    def test_sparse_csv_preserves_previous_state(self):
        changes = np.r_[True, np.any(np.diff(self.data[:, 1:], axis=0) != 0, axis=1)]
        changes[-1] = True
        self.assertEqual(self.verify(data=self.data[changes])["b_onset_model"],
                         "initial_b_fragment_interval_v1")

    def test_requires_explicit_interval_model_and_same_press(self):
        for options in (dict(enabled=False), dict(anchor=False)):
            with self.assertRaises(ValueError):
                self.verify(**options)

    def test_no_recovery_for_later_reopening(self):
        data = self.data.copy()
        data[(self.t >= .004235) & (self.t < .00424), 3] = 1
        with self.assertRaises(ValueError):
            self.verify(data=data, column=data[:, 3]*3.3)

    def test_no_recovery_when_next_window_missing(self):
        data = self.data.copy()
        data[(self.t >= .004225) & (self.t < .004251), 3] = 1
        with self.assertRaises(ValueError):
            self.verify(data=data)

    def test_raw_analog_high_over_one_us_rejected(self):
        column = self.column.copy()
        column[(self.t >= .004028) & (self.t < .0040295)] = 3.3
        with self.assertRaises(ValueError):
            self.verify(column=column)
        from scan_latency_validation import check_fragmented_b_scope
        contact = self.verify()["b_midwindow_contact"]
        with self.assertRaisesRegex(ValueError, "模拟列高段"):
            check_fragmented_b_scope(contact, self.scope_t, column,
                                     1.00003, .003, 2.2e-6, 2e-6)

    def test_raw_analog_tail_high_rejected_even_below_one_us(self):
        column = self.column.copy()
        column[(self.t >= .004041) & (self.t < .0040412)] = 3.3
        with self.assertRaisesRegex(ValueError, "稳定原始模拟低"):
            self.verify(column=column)

    def test_unrelated_fragment_outside_first_b_rejected(self):
        data = self.data.copy()
        data[(self.t >= .00315) & (self.t < .0031515), 3] = 0
        with self.assertRaises(ValueError):
            self.verify(data=data)

    def test_remaining_sync_edges_are_not_relaxed(self):
        column = self.column.copy()
        column[(self.t >= .006) & (self.t < .00601)] = 3.3
        with self.assertRaisesRegex(ValueError, "全起止沿"):
            self.verify(column=column)


class ShortInitialBTests(unittest.TestCase):
    def setUp(self):
        BoundaryTests.setUp(self)
        self.data[(self.t >= .004026) & (self.t < .004046), 3] = 1
        self.column = self.data[:, 3]*3.3

    def run_case(self, data=None, column=None):
        from scope_column_pulses import extract
        column = self.column if column is None else column
        dt = self.scope_t[1]-self.scope_t[0]
        s, e, _ = extract(column, dt)
        return verify(
            self.data if data is None else data, self.scope_t, column,
            .0106, 30, 25, 24_000_000,
            scope_intervals=(s*dt+.003, e*dt+.003),
            first_contact_anchor=True, allow_short_initial_b=True)

    def test_preserves_earliest_b_and_scan_allowance(self):
        result = self.run_case()
        self.assertEqual(result["b_onset_model"], "short_initial_b_tail_v1")
        self.assertAlmostEqual(result["b_window_scope_s"][0], .004025*1.00003+.003)
        self.assertAlmostEqual(result["conditional_closure_earliest_scope_s"], .003825*1.00003+.003)
        self.assertTrue(result["b_midwindow_contact"]["first_short_tail_is_not_sync_edge"])

    def test_analyze_auto_recovers_without_discarding_raw_short(self):
        original = self.data.copy()
        with tempfile.TemporaryDirectory() as temp:
            csv = Path(temp)/"digital.csv"
            csv.write_bytes(b"raw short tail")
            with patch("scan_latency_validation.read_csv", return_value=self.data), \
                    patch("latency_waveforms.load", return_value=(
                        (self.column, np.zeros(len(self.column))), 1.00003/24e6,
                        {"raw_sha256": {}, "version_user_recorded": {}})), \
                    patch("latency_waveforms.onsets", return_value=[{"onset_scope_s": .0076}]):
                result, *_ = analyze(Path(temp), csv, ("t", "a", "b", "c"),
                                     0, 0, True, 24_000_000, observation_only=True)
            self.assertEqual(result["analysis_model_version"], "digital_rows_v10_short_initial_b")
            self.assertIsNone(result["conditional_below_5ms"])
            self.assertEqual(csv.read_bytes(), b"raw short tail")
        np.testing.assert_array_equal(self.data, original)

    def test_rejects_reopening_after_short_tail(self):
        data = self.data.copy()
        data[(self.t >= .004049) & (self.t < .004052), 3] = 1
        with self.assertRaises(ValueError):
            self.run_case(data=data)

    def test_rejects_earlier_b_contact_instead_of_selecting_later(self):
        data = self.data.copy()
        data[(self.t >= .003833) & (self.t < .0038345), 3] = 0
        with self.assertRaises(ValueError):
            self.run_case(data=data)

    def test_rejects_missing_following_b(self):
        data = self.data.copy()
        data[(self.t >= .004233) & (self.t < .00424), 3] = 1
        with self.assertRaises(ValueError):
            self.run_case(data=data)

    def test_requires_raw_analog_stable_low(self):
        column = self.column.copy()
        column[(self.t >= .004046) & (self.t < .004052)] = 3.3
        with self.assertRaisesRegex(ValueError, "独立模拟"):
            self.run_case(column=column)

    def test_other_intermediate_event_is_not_hidden(self):
        data = self.data.copy()
        data[(self.t >= .00615) & (self.t < .006153), 3] = 0
        with self.assertRaises(SignalEvidenceError):
            self.run_case(data=data)


class PreviousAContactTests(unittest.TestCase):
    def setUp(self):
        BoundaryTests.setUp(self)
        self.data[(self.t >= .001817) & (self.t < .0018255), 3] = 0
        self.column = self.data[:, 3]*3.3

    def run_case(self, data=None, column=None):
        from scope_column_pulses import extract
        column = self.column if column is None else column
        dt = self.scope_t[1]-self.scope_t[0]
        s, e, _ = extract(column, dt)
        return verify(
            self.data if data is None else data, self.scope_t, column,
            .0106, 30, 25, 24_000_000,
            scope_intervals=(s*dt+.003, e*dt+.003),
            first_contact_anchor=True, allow_previous_a_contact=True)

    def test_keeps_partial_a_b_origin_and_raw_data(self):
        original = self.data.copy()
        result = self.run_case()
        self.assertEqual(result["previous_a_contact"]["model"],
                         "previous_a_contact_interval_v1")
        self.assertTrue(result["previous_a_contact"]["analog_raw_b_cores_high"])
        self.assertAlmostEqual(result["b_window_scope_s"][0], .004025*1.00003+.003)
        self.assertEqual(result["excluded_short_low_pulses"]["column"], 0)
        np.testing.assert_array_equal(original, self.data)

    def test_auto_analyze_handles_analog_partial_over_ten_us(self):
        column = self.column.copy()
        column[(self.t >= .001814) & (self.t < .001826)] = 0
        original = column.copy()
        with tempfile.TemporaryDirectory() as temp:
            csv = Path(temp)/"digital.csv"
            csv.write_bytes(b"raw retained")
            with patch("scan_latency_validation.read_csv", return_value=self.data), \
                    patch("latency_waveforms.load", return_value=(
                        (column, np.zeros(len(column))), 1.00003/24e6,
                        {"raw_sha256": {}, "version_user_recorded": {}})), \
                    patch("latency_waveforms.onsets", return_value=[{"onset_scope_s": .0076}]):
                result, *rest = analyze(
                    Path(temp), csv, ("t", "a", "b", "c"), 0, 0, True,
                    24_000_000, observation_only=True)
            self.assertEqual(result["analysis_model_version"], "digital_rows_v9_previous_a_interval")
            self.assertAlmostEqual(rest[-1], .001814*1.00003)
            self.assertIsNone(result["conditional_below_5ms"])
            self.assertFalse(result["error_budget_verified"])
            self.assertEqual(csv.read_bytes(), b"raw retained")
        np.testing.assert_array_equal(original, column)

    def test_rejects_b_contact_in_previous_frame(self):
        for start, end in ((.001833, .001838), (.002033, .002038)):
            data = self.data.copy()
            data[(self.t >= start) & (self.t < end), 3] = 0
            with self.assertRaises(ValueError):
                self.run_case(data=data)

    def test_rejects_analog_only_b_contact(self):
        column = self.column.copy()
        column[(self.t >= .001833) & (self.t < .001838)] = 0
        with self.assertRaisesRegex(ValueError, "模拟低超出|进入B内部"):
            self.run_case(column=column)

    def test_rejects_older_frame_and_outside_a_contact(self):
        for start in (.001615, .00175):
            data = self.data.copy()
            data[(self.t >= start) & (self.t < start+.5e-6), 3] = 0
            with self.assertRaises(ValueError):
                self.run_case(data=data)

    def test_requires_independent_analog_low(self):
        column = self.column.copy()
        column[self.t < .002] = 3.3
        with self.assertRaisesRegex(ValueError, "独立模拟低"):
            self.run_case(column=column)

    def test_does_not_hide_later_in_scope_artifacts(self):
        data = self.data.copy()
        data[(self.t >= .00615) & (self.t < .0061515), 3] = 0
        with self.assertRaises(SignalEvidenceError):
            self.run_case(data=data)

    def test_full_sync_tolerance_is_not_relaxed(self):
        column = self.column.copy()
        column[(self.t >= .006) & (self.t < .00601)] = 3.3
        with self.assertRaisesRegex(ValueError, "全起止沿"):
            self.run_case(column=column)


if __name__ == "__main__":
    unittest.main()

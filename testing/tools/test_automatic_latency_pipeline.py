"""Combined waveform cases use identical preliminary and final evidence rules."""

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
import test_scan_latency_validation as fixtures
import test_initial_a_fragments as first_a
from scan_latency_validation import (
    analyze, verify, pulses, recovery_candidates, common_scope_tail_window,
    SignalEvidenceError,
)


class AutomaticPipelineTests(unittest.TestCase):
    def fixture(self, kind):
        if kind in ("a_fragments_short_b", "previous_short_b", "a_fragments_b_fragments"):
            base = "previous" if kind == "previous_short_b" else "a_fragments"
            case = self.fixture(base)
            if kind == "a_fragments_b_fragments":
                other = self.fixture("b_fragments")
                after = case.t >= .003
                case.data[after, 3] = other.data[after, 3]
                case.column[after] = other.column[after]
            else:
                mask = (case.t >= .004026) & (case.t < .004046)
                case.data[mask, 3] = 1
                case.column[mask] = 3.3
            return case
        classes = dict(a=fixtures.InitialATransientTests,
                       a_fragments=first_a.FirstAFragmentTests,
                       previous=fixtures.PreviousAContactTests,
                       short_b=fixtures.ShortInitialBTests,
                       b_fragments=fixtures.FragmentedBTests)
        case = classes[kind]()
        case.setUp()
        return case

    def options(self, kind):
        result = dict(first_contact_anchor=True)
        if kind.startswith("a_fragments"):
            result["allow_initial_a_fragments"] = True
        if kind.startswith("previous"):
            result["allow_previous_a_contact"] = True
        if kind.endswith("short_b"):
            result["allow_short_initial_b"] = True
        if kind.endswith("b_fragments"):
            result["allow_fragmented_initial_b"] = True
        return result

    def combined(self, kind, event_time=.01615, width=1.5e-6):
        case = self.fixture(kind)
        extra = case.data.copy()
        extra[:, 0] += .01
        data = np.vstack((case.data, extra))
        data[(data[:, 0] >= event_time) & (data[:, 0] < event_time+width), 3] = 0
        intervals = pulses(case.scope_t, case.column < 1.5, trim=True)
        return case, data, intervals

    def test_all_supported_contacts_combine_with_late_artifacts(self):
        for kind in ("a", "a_fragments", "previous", "short_b", "b_fragments",
                     "a_fragments_short_b", "previous_short_b", "a_fragments_b_fragments"):
            for width in (.5e-6, 1.5e-6):
                with self.subTest(kind=kind, width=width):
                    case, data, intervals = self.combined(kind, width=width)
                    options = self.options(kind)
                    original = data.copy()
                    with self.assertRaises(SignalEvidenceError) as error:
                        verify(data, case.scope_t, case.column, .0106, 0, 0,
                               24_000_000, scope_intervals=intervals, **options)
                    bounded, policy = common_scope_tail_window(
                        data, case.scope_t, intervals, 24_000_000,
                        error.exception, **options)
                    result = verify(
                        bounded, case.scope_t, case.column, .0106, 0, 0,
                        24_000_000, scope_intervals=intervals, **options)
                    self.assertAlmostEqual(result["b_window_scope_s"][0],
                                           .004025*1.00003+.003)
                    self.assertAlmostEqual(policy["retained_tail_guard_us"], 1000)
                    np.testing.assert_array_equal(data, original)

    def test_combining_models_never_hides_in_scope_or_guard_events(self):
        for kind in ("a", "a_fragments", "previous", "short_b", "b_fragments",
                     "a_fragments_short_b", "previous_short_b", "a_fragments_b_fragments"):
            for when in (.00615, .01015):
                with self.subTest(kind=kind, when=when):
                    case, data, intervals = self.combined(kind, event_time=when)
                    options = self.options(kind)
                    with self.assertRaises(SignalEvidenceError) as error:
                        verify(data, case.scope_t, case.column, .0106, 0, 0,
                               24_000_000, scope_intervals=intervals, **options)
                    with self.assertRaises(ValueError):
                        common_scope_tail_window(
                            data, case.scope_t, intervals, 24_000_000,
                            error.exception, **options)

    def test_candidates_follow_waveform_not_target_key(self):
        expected = dict(a=[], a_fragments=[dict(initial_a_fragments=True)],
                        previous=[dict(previous_a=True)],
                        short_b=[dict(short_b=True)], b_fragments=[],
                        a_fragments_short_b=[dict(short_b=True), dict(initial_a_fragments=True),
                                             dict(initial_a_fragments=True, short_b=True)],
                        previous_short_b=[dict(previous_a=True), dict(short_b=True),
                                          dict(previous_a=True, short_b=True)],
                        a_fragments_b_fragments=[dict(initial_a_fragments=True)])
        for kind, options in expected.items():
            with self.subTest(kind=kind):
                self.assertEqual(recovery_candidates(self.fixture(kind).data), options)

    def test_retry_reads_raw_and_computes_same_onset_only_once(self):
        case = self.fixture("a_fragments")
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)/"digital.csv"
            source.write_bytes(b"unchanged source")
            with patch("scan_latency_validation.read_csv", return_value=case.data) as read, \
                    patch("latency_waveforms.load", return_value=(
                        (case.column, np.zeros(len(case.column))), 1.00003/24e6,
                        {"raw_sha256": {}, "version_user_recorded": {}})) as load, \
                    patch("latency_waveforms.onsets",
                          return_value=[{"onset_scope_s": .0076}]) as onsets:
                result, *_ = analyze(temp, source, ("t", "a", "b", "c"),
                                     0, 0, True, 24_000_000, observation_only=True)
            read.assert_called_once()
            load.assert_called_once()
            onsets.assert_called_once()
            self.assertTrue(result["automatic_handling"]["cached_raw_and_onsets"])
            self.assertEqual(result["automatic_handling"]["selected_options"],
                             dict(initial_a_fragments=True))
            self.assertIsNone(result["conditional_below_5ms"])
            self.assertEqual(source.read_bytes(), b"unchanged source")

    def test_failure_surfaces_actual_supported_model_blocker(self):
        case = self.fixture("a_fragments")
        column = case.column.copy()
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)/"digital.csv"
            source.write_bytes(b"unchanged source")
            with patch("scan_latency_validation.read_csv", return_value=case.data), \
                    patch("latency_waveforms.load", return_value=(
                        (column, np.zeros(len(column))), 1.00003/24e6,
                        {"raw_sha256": {}, "version_user_recorded": {}})), \
                    patch("latency_waveforms.onsets",
                          return_value=[{"onset_scope_s": .0076}]), \
                    patch("scan_latency_validation.check_initial_scope_interval",
                          side_effect=ValueError("缺少独立模拟列高证据")):
                with self.assertRaisesRegex(ValueError, "独立模拟列高") as error:
                    analyze(temp, source, ("t", "a", "b", "c"),
                            0, 0, True, 24_000_000, observation_only=True)
            self.assertEqual(error.exception.analysis_attempts[-1]["options"],
                             dict(initial_a_fragments=True))
            self.assertTrue(error.exception.initial_analysis_error)


if __name__ == "__main__":
    unittest.main()

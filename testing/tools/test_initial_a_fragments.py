"""First A fragments must be independently witnessed, never hidden as quiet."""

import unittest
import numpy as np

import test_scan_latency_validation as fixtures
from scan_latency_validation import verify, measurement_window, SignalEvidenceError


class FirstAFragmentTests(unittest.TestCase):
    def setUp(self):
        fixture = fixtures.InitialATransientTests()
        fixture.setUp()
        self.data = fixture.data.copy()
        self.t, self.scope_t = fixture.t, fixture.scope_t
        self.column = fixture.column.copy()
        self.data[(self.t >= .002004) & (self.t < .0020055), 3] = 0

    def verify(self, data=None, column=None):
        return verify(self.data if data is None else data, self.scope_t,
                      self.column if column is None else column,
                      .0106, 0, 0, 24_000_000, first_contact_anchor=True,
                      allow_initial_a_fragments=True)

    def test_fragment_interval_preserves_b_and_raw_events(self):
        result = self.verify()
        contact = result["initial_a_contact_transient"]
        self.assertEqual(contact["model"], "initial_a_fragment_interval_v1")
        self.assertTrue(contact["analog_following_b_core_high"])
        self.assertAlmostEqual(contact["events"][0]["width_us"], 1.5, places=5)
        self.assertAlmostEqual(result["b_window_scope_s"][0], .004025*1.00003+.003)
        self.assertEqual(contact["excluded_exact_sync_edges"], 1)
        self.assertEqual(result["excluded_short_low_pulses"]["column"], 0)

    def test_sparse_data_retains_fragment(self):
        changes = np.r_[True, np.any(np.diff(self.data[:, 1:], axis=0) != 0, axis=1)]
        changes[-1] = True
        self.assertEqual(self.verify(data=self.data[changes])[
            "initial_a_contact_transient"]["model"], "initial_a_fragment_interval_v1")

    def entry_case(self):
        data = self.data.copy()
        data[(self.t >= .002) & (self.t < .002008), 3] = 1
        data[(self.t >= .002001) & (self.t < .0020025), 3] = 0
        column = data[:, 3]*3.3
        return data, column

    def test_entry_fragments_inside_a_are_not_ab_boundary_events(self):
        data, column = self.entry_case()
        result = self.verify(data=data, column=column)
        contact = result["initial_a_contact_transient"]
        self.assertEqual(contact["entry_policy"],
                         "measured_A_fall_with_previous_B_separation")
        self.assertAlmostEqual(result["b_window_scope_s"][0], .004025*1.00003+.003)

    def test_close_fragment_does_not_require_two_us_gap(self):
        data = self.data.copy()
        data[(self.t >= .002) & (self.t < .002008), 3] = 1
        data[(self.t >= .0020067) & (self.t < .00200795), 3] = 0
        result = self.verify(data=data, column=data[:, 3]*3.3)
        self.assertTrue(result["initial_a_contact_transient"]["fragment_interval"])

    def test_entry_model_rejects_digital_contact_before_a(self):
        data, column = self.entry_case()
        data[(self.t >= .0019995) & (self.t < .0020005), 3] = 0
        with self.assertRaises(ValueError):
            self.verify(data=data, column=column)

    def test_entry_model_rejects_analog_contact_before_a(self):
        data, column = self.entry_case()
        column[(self.t >= .0019995) & (self.t < .002001)] = 0
        with self.assertRaises(ValueError):
            self.verify(data=data, column=column)

    def test_following_analog_b_core_must_be_high(self):
        column = self.column.copy()
        column[(self.t >= .002034) & (self.t < .0020355)] = 0
        with self.assertRaisesRegex(ValueError, "独立模拟列高"):
            self.verify(column=column)

    def test_analog_low_in_other_a_window_is_rejected(self):
        column = self.column.copy()
        column[(self.t >= .001804) & (self.t < .0018055)] = 0
        with self.assertRaises(ValueError):
            self.verify(column=column)

    def test_digital_fragment_in_other_window_is_rejected(self):
        data = self.data.copy()
        data[(self.t >= .001804) & (self.t < .0018055), 3] = 0
        with self.assertRaises(ValueError):
            self.verify(data=data)

    def test_later_fragment_is_not_covered_by_initial_a_model(self):
        data = self.data.copy()
        data[(self.t >= .00219) & (self.t < .0021915), 3] = 0
        with self.assertRaises(SignalEvidenceError):
            self.verify(data=data)

    def test_missing_analog_first_a_is_rejected(self):
        column = self.column.copy()
        column[self.t < .0022] = 3.3
        with self.assertRaises(ValueError):
            self.verify(column=column)

    def test_measurement_window_preserves_fragment_and_precontact_time(self):
        data = self.data.copy()
        data[:, 0] += .02
        prefix = self.data.copy()
        prefix[:, 3] = 1
        data = np.vstack((prefix, data))
        with self.assertRaises(SignalEvidenceError):
            measurement_window(data)
        cropped, policy = measurement_window(data, allow_initial_a_fragments=True)
        self.assertIn("first_a_fragments_preserved", policy)
        self.assertLess(cropped[0, 0], .022004)
        self.assertGreater(policy["first_a_fragments_preserved"]["events"][0]["width_us"], 1)


if __name__ == "__main__":
    unittest.main()

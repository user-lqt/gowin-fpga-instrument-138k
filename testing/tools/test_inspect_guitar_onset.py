"""No device access. Verify the distinction between points and duration."""

import unittest

import numpy as np

from inspect_guitar_onset import sampled_detail, full_grid_detail, runs


class DiagnosticTests(unittest.TestCase):
    def fixture(self):
        signal = np.zeros(12000)
        # Ten 100kHz sample points, but not 100 us of continuous support.
        signal[6000:6091] = .030
        signal[8000:8200] = .030
        return signal

    def test_ten_points_span_ninety_us(self):
        # Match the real capture interval and decimation factor.
        fine = np.repeat(self.fixture(), 200)
        detail = sampled_detail(fine, 2000, 5e-9, .004, 0, .020)
        self.assertEqual(detail["required_samples"], 10)
        self.assertAlmostEqual(detail["sampled_first_to_last_span_us"], 90)
        self.assertAlmostEqual(detail["onset_scope_s"], .006)

    def test_full_grid_rejects_short_run(self):
        result = full_grid_detail(self.fixture(), 1e-6, .004, 0, .020)
        self.assertAlmostEqual(result["onset_scope_s"], .008)

    def test_notch_between_samples_is_not_detected_by_sample_points(self):
        signal = np.repeat(self.fixture(), 200)
        signal[1200500:1200600] = 0
        sampled = sampled_detail(signal, 2000, 5e-9, .004, 0, .020)
        grid = full_grid_detail(signal, 5e-9, .004, 0, .020)
        self.assertAlmostEqual(sampled["onset_scope_s"], .006)
        self.assertAlmostEqual(grid["onset_scope_s"], .008)

    def test_runs_preserve_first_and_final_intervals(self):
        start, stop = runs(np.array([True, True, False, True]))
        np.testing.assert_array_equal(start, [0, 3])
        np.testing.assert_array_equal(stop, [2, 4])


if __name__ == "__main__":
    unittest.main()

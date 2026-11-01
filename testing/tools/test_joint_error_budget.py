import unittest

import numpy as np
from scipy.signal import convolve, firwin, resample_poly

from evaluate_joint_error_budget import (
    THRESHOLD_EPSILON_V, conditional_budget_ms, full_phase_filter,
    phase_onsets, rounded_allowance_us,
)


class PhaseBudgetTests(unittest.TestCase):
    def setUp(self):
        self.dt = 1e-6
        self.factor = 40
        self.anchor = .004
        t = np.arange(14000) * self.dt
        rng = np.random.default_rng(19)
        self.signal = rng.normal(0, .0002, len(t))
        self.signal += (t > .007123) * (.05 * np.sin(2 * np.pi * 800 * t))

    def test_fir_zero_phase_matches_scipy(self):
        for factor in (10, 20, 40):
            y, offset, error = full_phase_filter(self.signal, factor, "polyphase")
            np.testing.assert_allclose(y[::factor], resample_poly(
                self.signal, 1, factor), atol=1e-12)
            self.assertEqual(offset, 0)
            self.assertLess(error, 1e-12)

    def test_every_phase_against_independent_direct_convolution(self):
        for method in ("polyphase", "block_mean"):
            y, offset, _ = full_phase_filter(self.signal, self.factor, method)
            rows = phase_onsets(y, self.factor, self.dt, self.anchor, offset)
            if method == "polyphase":
                taps = firwin(20 * self.factor + 1, 1 / self.factor,
                              window=("kaiser", 5.0))
                direct = convolve(self.signal, taps, mode="same", method="direct")
            for phase in range(self.factor):
                if method == "polyphase":
                    values = direct[phase::self.factor]
                    t = (np.arange(len(values)) * self.factor + phase) * self.dt
                else:
                    n = (len(self.signal) - phase) // self.factor
                    values = self.signal[phase:phase+n*self.factor].reshape(
                        -1, self.factor).mean(1)
                    t = (np.arange(n) * self.factor + phase + offset) * self.dt
                center = np.median(values[
                    (t > self.anchor-.0035) & (t < self.anchor-.0005)])
                length = int(np.ceil(.0001/(self.factor*self.dt)))
                for row in rows:
                    above = (abs(values-center) > row["threshold_mV"]/1000
                             + THRESHOLD_EPSILON_V) & (t > self.anchor)
                    valid = np.convolve(above.astype(int), np.ones(length, int), "valid")
                    expected = t[np.flatnonzero(valid >= length)[0]]
                    self.assertAlmostEqual(row["onsets"][phase], expected, places=12)

    def test_missing_onset_rejected(self):
        with self.assertRaises(ValueError):
            phase_onsets(np.zeros(14000), 40, self.dt, self.anchor, 0)

    def test_insufficient_baseline_rejected(self):
        with self.assertRaises(ValueError):
            phase_onsets(self.signal, 40, self.dt, .0001, 0)

    def test_allowance_is_only_positive_increment_rounded_up(self):
        self.assertEqual(rounded_allowance_us([0, 1, 29.1]), 30)
        self.assertEqual(rounded_allowance_us([0, 0]), 0)
        with self.assertRaises(ValueError):
            rounded_allowance_us([float("nan")])

    def test_budget_scales_entire_envelope_includes_skew(self):
        self.assertAlmostEqual(conditional_budget_ms(3.8, 30, 0),
                               (3.83+.000002)/(1-25e-6), places=12)
        self.assertGreater(conditional_budget_ms(3.8, 30, 10),
                           conditional_budget_ms(3.8, 30, 0))
        for invalid in (-1, float("nan"), float("inf")):
            with self.assertRaises(ValueError):
                conditional_budget_ms(3.8, 30, invalid)


if __name__ == "__main__":
    unittest.main()

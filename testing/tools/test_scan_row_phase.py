"""A missing measured row cannot be repaired by shifting its time axis."""

import unittest
from unittest.mock import patch

import numpy as np

from scan_latency_validation import SignalEvidenceError, analyze, row_column_mismatch


class RowPhaseTests(unittest.TestCase):
    def fixture(self, column_phase=100):
        ticks = np.arange(24000)
        t = ticks*.5e-6
        phase = ticks % 400
        a = np.where(phase < 50, 0, 1)
        b = np.where((phase >= 50) & (phase < 100), 0, 1)
        c = np.where((ticks > 2000) & (phase >= column_phase)
                     & (phase < column_phase+48), 0, 1)
        return np.column_stack((t, a, b, c))

    def test_wrong_slot_is_diagnostic_not_acceptance(self):
        result = row_column_mismatch(self.fixture())
        self.assertEqual(result["category"], "row_column_phase_mismatch")
        self.assertEqual(result["row_core_column_low_counts"], {"A": 0, "B": 0})
        self.assertAlmostEqual(result["column_after_A_us"]["median"], 50)
        self.assertNotIn("conditional_below_5ms", result)

    def test_matching_either_row_is_not_mismatch(self):
        for phase in (0, 50):
            with self.subTest(phase=phase):
                self.assertIsNone(row_column_mismatch(self.fixture(phase)))

    def test_early_startup_transient_does_not_hide_later_phase_mismatch(self):
        data = self.fixture()
        data[15:50, 1] = 1
        self.assertIsNotNone(row_column_mismatch(data))

    def test_no_column_signal_does_not_claim_wrong_slot(self):
        data = self.fixture()
        data[:, 3] = 1
        self.assertIsNone(row_column_mismatch(data))

    def test_insufficient_or_invalid_rows_do_not_claim_wrong_slot(self):
        self.assertIsNone(row_column_mismatch(self.fixture()[:1000]))
        data = self.fixture()
        data[:, 1] = 1
        self.assertIsNone(row_column_mismatch(data))

    def test_success_is_never_reclassified(self):
        with patch("scan_latency_validation._analyze", return_value="original") as call, \
                patch("scan_latency_validation.read_csv") as read:
            self.assertEqual(analyze("trial", "csv", (), 0, 0, True), "original")
            call.assert_called_once()
            read.assert_not_called()

    def test_proven_absent_rows_skip_inapplicable_recovery_models(self):
        with patch("scan_latency_validation._analyze", side_effect=ValueError("旧错误")) as call, \
                patch("scan_latency_validation.read_csv", return_value=self.fixture()):
            with self.assertRaises(SignalEvidenceError) as error:
                analyze("trial", "csv", (), 0, 0, True)
            call.assert_called_once()
            self.assertEqual(error.exception.details["category"], "row_column_phase_mismatch")


if __name__ == "__main__":
    unittest.main()

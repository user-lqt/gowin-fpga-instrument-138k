"""Chinese report rendering must preserve measurements and machine contracts."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import warnings

import numpy as np

from polyphony_acceptance import acceptance_reports as reports
from polyphony_acceptance.report_chinese import metadata_rows


class ChineseReportTests(unittest.TestCase):
    def test_summary_fields_and_values_are_chinese(self):
        text = metadata_rows(dict(measured_lrck_hz=48000, rtl_independence_verified=False,
                                  contest_acceptance="NOT_DETERMINED",
                                  spectral_tool_check="PASS", kind="lrck_analysis"))
        self.assertIn("LRCK 实测频率", text)
        self.assertIn("未执行；不代表未人工核实", text)
        self.assertIn("未判定", text)
        self.assertIn("通过", text)
        for raw in ("measured_lrck_hz", "False", "NOT_DETERMINED", "PASS", "lrck_analysis"):
            self.assertNotIn(raw, text)

    def test_human_verification_is_not_shown_as_missing_software_verification(self):
        text = metadata_rows(dict(
            declared_independent_oscillators=64,
            independent_oscillator_count_user_verified=True,
            verified_independent_oscillators=None,
            confirmed_oscillator_samples_per_second=None,
            rtl_independence_verified=False))
        self.assertIn("已人工核实，依据见技术文档", text)
        self.assertIn("软件自动审查 RTL 得到", text)
        self.assertIn("不出具正式比赛评分", text)
        self.assertNotIn("独立振荡器数量未核实", text)
        self.assertNotIn("待 RTL 核查", text)

    def test_polyphony_page_plots_and_saved_regeneration(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            hz = np.linspace(500, 1100, 2400)
            magnitude = .001 + np.exp(-((hz - 753) / 2) ** 2)
            rows = [dict(voice=i + 1, enabled=i == 0, nominal_hz=f,
                         predicted_hz=f, measured_hz=f + .5, amplitude_peak=1 if i == 0 else .001,
                         relative_db=0, snr_db=50, present=i == 0, match=True)
                    for i, f in enumerate((752.9, 846.7))]
            result = dict(source="DAC_OUTPUT_SCOPE_CAPTURE", voices=2, selection=5,
                          spectral_check="PASS", record_seconds=.7, bin_spacing_hz=1.19,
                          clock_ratio=1, rows=rows, matched_enabled_peaks=1, expected_peaks=1)
            with warnings.catch_warnings(record=True) as caught:
                warnings.simplefilter("always")
                reports.save_overview(folder, result, hz, magnitude)
                reports.save_details(folder, result, hz, magnitude)
            self.assertFalse([w for w in caught if "missing from font" in str(w.message)])
            text = (folder / "report.html").read_text(encoding="utf-8")
            for expected in ("复音频率测量证据", "频率明细", "工具自检：通过", 'lang="zh-CN"'):
                self.assertIn(expected, text)
            for old in ("Polyphony Frequency Evidence", "Nominal Hz", "OFF", "PASS", "DAC_OUTPUT_SCOPE_CAPTURE"):
                self.assertNotIn(old, text)
            self.assertIn("设计频率", (folder / "frequency_errors.csv").read_text(encoding="utf-8-sig"))
            (folder / "analysis.json").write_text(json.dumps(result), encoding="utf-8")
            paths = [folder / "analysis.json", folder / "spectrum_plot.npz"]
            before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
            reports.regenerate(folder)
            self.assertTrue(all(hashlib.sha256(p.read_bytes()).hexdigest() == h for p, h in before.items()))
            self.assertTrue((folder / "zoom_01_02.png").is_file())


if __name__ == "__main__":
    unittest.main()

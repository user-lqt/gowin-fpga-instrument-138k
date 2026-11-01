"""Offline frequency, artifact-integrity, and STOP-only transport checks."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch

import numpy as np

import acceptance_evidence as evidence
import lrck_measurement as lrck


def waveform(hz=48000, fs=10_000_000, seconds=.005):
    t = np.arange(round(fs * seconds)) / fs
    return np.where((t * hz) % 1 < .5, 3.28, 0)


def record(folder):
    folder.mkdir()
    data = np.where(waveform() > 1, 122, 40).astype(np.uint8).tobytes()
    pre = f"0,2,{len(data)},1,0.0000001,-0.002,0,0.04,40,0"
    meta = dict(kind="lrck", status="complete", firmware_user_reported="test-image-only",
                wiring_user_confirmed=True, scope_identity="offline fixture",
                waveform=dict(preamble=pre, sha256=hashlib.sha256(data).hexdigest()))
    lrck.write_json(folder / "capture.json", meta)
    (folder / "raw.bin").write_bytes(data)
    (folder / "screen.bmp").write_bytes(b"BM")
    return data, meta


class EdgeTests(unittest.TestCase):
    def test_frequency_uses_full_period_not_both_edges(self):
        result, _ = lrck.analyze_edges(waveform(), 1e-7)
        self.assertAlmostEqual(result["measured_lrck_hz"], 48000, delta=3)
        self.assertGreater(result["complete_periods"], 200)
        self.assertAlmostEqual(result["mean_period_us"], 20.8333, delta=.01)

    def test_other_audio_rate(self):
        result, _ = lrck.analyze_edges(waveform(44100), 1e-7)
        self.assertAlmostEqual(result["measured_lrck_hz"], 44100, delta=3)

    def test_flat_too_short_bck_and_undersampled_rejected(self):
        for y, dt in ((np.zeros(5000), 1e-7),
                      (waveform(seconds=.0001), 1e-7),
                      (waveform(3_072_000), 1e-7),
                      (waveform(fs=480000), 1 / 480000)):
            with self.subTest(dt=dt, points=len(y)), self.assertRaises(ValueError):
                lrck.analyze_edges(y, dt)

    def test_missing_clock_cycle_rejected(self):
        y = waveform()
        y[10000:10500] = 0
        with self.assertRaisesRegex(ValueError, "周期变化"):
            lrck.analyze_edges(y, 1e-7)

    def test_reports_and_hash_tampering(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / "lrck"
            record(folder)
            report = lrck.generate(folder)
            self.assertTrue(report.is_file())
            self.assertTrue((folder / "periods.csv").is_file())
            self.assertTrue((folder / "lrck_waveform.png").is_file())
            text = report.read_text(encoding="utf-8")
            self.assertIn("不证明无抖动", text)
            (folder / "raw.bin").write_bytes(b"bad")
            with self.assertRaises(ValueError):
                lrck.generate(folder)

    def test_score_is_conditional_even_with_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            folder = root / "lrck"
            record(folder)
            lrck.generate(folder)
            poly = root / "all"
            poly.mkdir()
            data = bytes([100]) * 40000
            (poly / "raw.bin").write_bytes(data)
            lrck.write_json(poly / "capture.json", dict(
                kind="DAC_OUTPUT_SCOPE_CAPTURE", complete=True,
                operator_declared_voices=64, operator_declared_selection=0,
                preamble=[0, 2, len(data), 1, 1e-5, 0, 0, .02, 0, 127],
                raw_sha256=hashlib.sha256(data).hexdigest()))
            lrck.write_json(poly / "analysis.json", dict(
                source="DAC_OUTPUT_SCOPE_CAPTURE", samples=len(data),
                capture_sha256=hashlib.sha256(data).hexdigest(),
                sample_rate_hz=100000, selection=0, voices=64,
                expected_peaks=64, matched_enabled_peaks=64, spectral_check="PASS"))
            evidence.generate(folder, poly, root / "summary")
            result = json.loads((root / "summary/summary.json").read_text(encoding="utf-8"))
            self.assertFalse(result["rtl_independence_verified"])
            self.assertFalse(result["same_loaded_firmware_verified"])
            self.assertEqual(result["contest_acceptance"], "NOT_DETERMINED")
            self.assertEqual(result["configured_voices"], 64)
            self.assertIsNone(result["verified_independent_oscillators"])
            self.assertIsNone(result["confirmed_oscillator_samples_per_second"])
            self.assertFalse(result["recorded_firmware_hashes_match"])
            self.assertTrue(result["all_output_spectral_evidence_complete"])
            self.assertIsNone(result["declared_independent_oscillators"])
            self.assertIsNone(result["conditional_oscillator_samples_per_second"])
            text = (root / "summary/report.html").read_text(encoding="utf-8")
            self.assertIn("暂不计算", text)
            self.assertNotIn("人工声明 64 ×", text)
            evidence.generate(folder, poly, root / "selected", declared_count=32)
            selected = json.loads((root / "selected/summary.json").read_text(encoding="utf-8"))
            self.assertEqual(selected["declared_independent_oscillators"], 32)
            self.assertAlmostEqual(selected["conditional_oscillator_samples_per_second"],
                                   32 * selected["measured_output_sample_rate_hz"])
            self.assertIsNone(selected["verified_independent_oscillators"])
            self.assertIsNone(selected["confirmed_oscillator_samples_per_second"])
            self.assertIn("技术文档", (root / "selected/report.html").read_text(encoding="utf-8"))
            self.assertFalse(selected["independent_oscillator_count_user_verified"])
            evidence.generate(folder, poly, root / "human_verified", declared_count=64,
                              count_user_verified=True)
            human = json.loads((root / "human_verified/summary.json").read_text(encoding="utf-8"))
            self.assertTrue(human["independent_oscillator_count_user_verified"])
            self.assertIn("已人工核实", human["independent_oscillator_count_basis"])
            self.assertFalse(human["rtl_independence_verified"])
            self.assertFalse(human["same_loaded_firmware_verified"])
            self.assertIsNone(human["verified_independent_oscillators"])
            self.assertIsNone(human["confirmed_oscillator_samples_per_second"])
            self.assertEqual(human["contest_acceptance"], "NOT_DETERMINED")
            self.assertEqual(human["conditional_oscillator_samples_per_second"],
                             64 * human["measured_output_sample_rate_hz"])
            text = (root / "human_verified/report.html").read_text(encoding="utf-8")
            for required in ("64 个", "已人工核实", "依据见技术文档", "非软件自动审查",
                             "分组 / 静音对照", "实时合成、无预录播放", "固件与工程构建对应"):
                self.assertIn(required, text)
            for obsolete in ("评分证据汇总：待核实", "待补充核查", "软件未核实",
                             "待 RTL 核查", "独立振荡器数量未核实"):
                self.assertNotIn(obsolete, text)
            for kwargs in (dict(count_user_verified=True),
                           dict(declared_count=64, count_user_verified="yes"),
                           dict(declared_count=64, count_user_verified=1)):
                with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                    evidence.generate(folder, poly, root / "invalid-confirmation", **kwargs)
            for invalid in (0, 4097, True, 1.5, "64"):
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    evidence.generate(folder, poly, root / "invalid", declared_count=invalid)
            with self.assertRaises(FileExistsError):
                evidence.generate(folder, poly, root / "summary")
            analysis = json.loads((poly / "analysis.json").read_text(encoding="utf-8"))
            analysis["matched_enabled_peaks"] = 63
            analysis["spectral_check"] = "FAIL"
            lrck.write_json(poly / "analysis.json", analysis)
            evidence.generate(folder, poly, root / "incomplete")
            result = json.loads((root / "incomplete/summary.json").read_text(encoding="utf-8"))
            self.assertFalse(result["all_output_spectral_evidence_complete"])
            self.assertIsNone(result["confirmed_oscillator_samples_per_second"])
            analysis["capture_sha256"] = "stale"
            lrck.write_json(poly / "analysis.json", analysis)
            with self.assertRaisesRegex(ValueError, "采集参数不一致"):
                evidence.generate(folder, poly, root / "stale")
            analysis["capture_sha256"] = hashlib.sha256(data).hexdigest()
            analysis["bitstream_sha256"] = "a" * 64
            meta = json.loads((poly / "capture.json").read_text(encoding="utf-8"))
            meta["bitstream_sha256"] = "a" * 64
            lrck.write_json(poly / "capture.json", meta)
            lrck.write_json(poly / "analysis.json", analysis)
            lmeta = json.loads((folder / "capture.json").read_text(encoding="utf-8"))
            lmeta["bitstream_sha256_user_file"] = "a" * 64
            lrck.write_json(folder / "capture.json", lmeta)
            lrck.generate(folder)
            evidence.generate(folder, poly, root / "matching")
            result = json.loads((root / "matching/summary.json").read_text(encoding="utf-8"))
            self.assertTrue(result["recorded_firmware_hashes_match"])
            self.assertFalse(result["same_loaded_firmware_verified"])
            self.assertIsNone(result["confirmed_oscillator_samples_per_second"])
            meta["bitstream_sha256"] = "b" * 64
            lrck.write_json(poly / "capture.json", meta)
            with self.assertRaisesRegex(ValueError, "哈希不同"):
                evidence.generate(folder, poly, root / "mismatching")
            (folder / "capture.json").write_text("{}", encoding="utf-8")
            with self.assertRaises(ValueError):
                evidence.generate(folder, poly, root / "bad")

    def test_network_capture_only_writes_transfer_settings(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            data, meta = record(root / "fixture")
            scope = MagicMock()
            stream = scope.makefile.return_value.__enter__.return_value
            values = {
                "*IDN?": "RIGOL TECHNOLOGIES,DS2202A,offline,1",
                ":TRIG:STAT?": "STOP", ":ACQ:TYPE?": "NORM", ":CHAN1:DISP?": "1",
                ":ACQ:SRAT?": "10000000", ":TIM:SCAL?": ".0001", ":TIM:OFFS?": "0",
                ":CHAN1:SCAL?": "1", ":CHAN1:OFFS?": "0",
                ":CHAN1:COUP?": "DC", ":CHAN1:PROB?": "10",
                ":WAV:SOUR?": "CHAN2", ":WAV:MODE?": "RAW", ":WAV:FORM?": "BYTE",
                ":WAV:STAR?": "1", ":WAV:STOP?": "1400",
                ":WAV:PRE?": meta["waveform"]["preamble"], ":SYST:ERR?": '0,"No error"',
            }
            latest = {}

            def send(raw):
                command = raw.decode().strip()
                latest["command"] = command
                if command.startswith(":WAV:") and " " in command:
                    key, value = command.split(" ", 1)
                    values[key + "?"] = value

            stream.readline.side_effect = lambda _limit: (values[latest["command"]] + "\n").encode()
            scope.sendall.side_effect = send
            with patch.object(lrck.socket, "create_connection") as connect, \
                    patch.object(lrck, "block", side_effect=[b"BM", data]):
                connect.return_value.__enter__.return_value = scope
                lrck.capture("offline", 1, root / "captured", "test", lambda *_: None, True)
            commands = [call.args[0].decode().strip() for call in scope.sendall.call_args_list]
            writes = [c for c in commands if "?" not in c]
            self.assertTrue(all(c.startswith(":WAV:") for c in writes), writes)
            self.assertEqual(values[":WAV:SOUR?"], "CHAN2")
            self.assertEqual(values[":WAV:STOP?"], "1400")
            self.assertTrue((root / "captured/report.html").is_file())


if __name__ == "__main__":
    unittest.main()

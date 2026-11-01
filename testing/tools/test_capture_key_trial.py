import contextlib
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch

from capture_key_trial import (
    BinaryTransferError, block, download_channel, main, restore_transfer, prepare_channel,
)


class FakeScope:
    def __init__(self, points=200003, failures=0):
        self.preamble = f"0,2,{points},1,1e-8,0,0,0.04,8,127"
        self.values = {
            ":TRIG:STAT?": "STOP", ":WAV:SOUR?": "CHAN1",
            ":WAV:MODE?": "RAW", ":WAV:FORM?": "BYTE",
            ":WAV:PRE?": self.preamble,
            ":WAV:STAR?": "1", ":WAV:STOP?": "1400",
        }
        self.failures = failures
        self.commands = []
        self.reads = []
        self.stream = io.BytesIO()
        self.short = False
        self.truncated = False

    def send(self, command):
        self.commands.append(command)
        if command.startswith(":WAV:STAR "):
            value = command.split()[-1]
            self.values[":WAV:STAR?"] = "0" if self.failures else value
            self.failures = max(0, self.failures - 1)
        elif command.startswith(":WAV:STOP "):
            self.values[":WAV:STOP?"] = command.split()[-1]
        elif command == ":WAV:DATA?":
            size = int(self.values[":WAV:STOP?"]) - int(self.values[":WAV:STAR?"]) + 1
            if self.short:
                size -= 1
            text = str(size).encode()
            payload = b"x" * size
            self.stream.seek(0)
            self.stream.truncate()
            self.stream.write(b"#" + str(len(text)).encode() + text + payload +
                              (b"" if self.truncated else b"\n"))
            self.stream.seek(0)

    def query(self, command):
        self.reads.append(command)
        return self.values[command]


class DownloadTests(unittest.TestCase):
    def run_download(self, scope, entry=None):
        if entry is None:
            entry = {"preamble": scope.preamble}
        target = io.BytesIO()
        points = int(scope.preamble.split(",")[2])
        with contextlib.redirect_stdout(io.StringIO()):
            download_channel(scope.send, scope.query, scope.stream,
                             target, 1, points, entry)
        return target.getvalue(), entry

    def test_complete_and_last_short_chunk(self):
        scope = FakeScope()
        data, entry = self.run_download(scope)
        self.assertEqual(len(data), 200003)
        self.assertEqual(entry["downloaded_points"], 200003)
        self.assertEqual(entry["sha256"], hashlib.sha256(data).hexdigest())
        self.assertNotIn("pending_range", entry)
        self.assertEqual(scope.commands.count(":WAV:DATA?"), 3)
        self.assertFalse(any("RUN" in c or "SING" in c for c in scope.commands))

    def test_transient_mismatch_recovers_before_data(self):
        scope = FakeScope(failures=1)
        _, entry = self.run_download(scope)
        self.assertEqual(len(entry["range_recovery"]), 2)
        self.assertEqual(scope.commands.count(":WAV:DATA?"), 3)
        self.assertEqual(scope.reads.count(":WAV:STAR?"),
                         scope.reads.count(":WAV:STOP?"))

    def test_persistent_mismatch_never_requests_data(self):
        scope = FakeScope(failures=100)
        entry = {"preamble": scope.preamble}
        with self.assertRaisesRegex(ValueError, "已尝试3次"):
            self.run_download(scope, entry)
        self.assertNotIn(":WAV:DATA?", scope.commands)
        self.assertEqual(entry["downloaded_points"], 0)
        self.assertEqual(len(entry["range_recovery"]), 3)

    def test_changed_capture_rejected(self):
        for command, value in (
            (":TRIG:STAT?", "RUN"), (":WAV:SOUR?", "CHAN2"),
            (":WAV:MODE?", "NORM"), (":WAV:FORM?", "WORD"),
            (":WAV:PRE?", "changed"),
        ):
            with self.subTest(command=command):
                scope = FakeScope()
                scope.values[command] = value
                with self.assertRaisesRegex(RuntimeError, "采集状态"):
                    self.run_download(scope)
                self.assertNotIn(":WAV:DATA?", scope.commands)

    def test_short_block_not_retried(self):
        scope = FakeScope()
        scope.short = True
        entry = {"preamble": scope.preamble}
        with self.assertRaisesRegex(ValueError, "数据长度不符"):
            self.run_download(scope, entry)
        self.assertEqual(scope.commands.count(":WAV:DATA?"), 1)
        self.assertEqual(entry["downloaded_points"], 0)

    def test_truncated_block_not_retried(self):
        scope = FakeScope()
        scope.truncated = True
        with self.assertRaisesRegex(ValueError, "terminator"):
            self.run_download(scope)
        self.assertEqual(scope.commands.count(":WAV:DATA?"), 1)

    def test_changed_capture_during_recovery(self):
        scope = FakeScope(failures=1)
        original_query = scope.query

        def query(command):
            if command == ":WAV:STOP?":
                scope.values[":TRIG:STAT?"] = "RUN"
            return original_query(command)

        scope.query = query
        with self.assertRaisesRegex(RuntimeError, "采集状态"):
            self.run_download(scope)
        self.assertNotIn(":WAV:DATA?", scope.commands)

    def test_partial_count_preserved_on_later_failure(self):
        scope = FakeScope()
        entry = {"preamble": scope.preamble}
        original_send = scope.send

        def send(command):
            if command == ":WAV:STAR 100001":
                scope.failures = 100
            original_send(command)

        scope.send = send
        with self.assertRaisesRegex(ValueError, "已保存 100000 点"):
            self.run_download(scope, entry)
        self.assertEqual(entry["downloaded_points"], 100000)
        self.assertEqual(entry["pending_range"], {"start": 100001, "stop": 200000})
        self.assertNotIn("sha256", entry)

    def test_previous_channel_range_is_replaced(self):
        scope = FakeScope()
        scope.values[":WAV:STAR?"] = "6900001"
        scope.values[":WAV:STOP?"] = "7000000"
        data, _ = self.run_download(scope)
        self.assertEqual(len(data), 200003)
        self.assertEqual(scope.commands[:2],
                         [":WAV:STOP 100000", ":WAV:STAR 1"])

    def test_post_download_change_does_not_get_verified_hash(self):
        scope = FakeScope(points=10)
        entry = {"preamble": scope.preamble}
        original_send = scope.send

        def send(command):
            original_send(command)
            if command == ":WAV:DATA?":
                scope.values[":WAV:PRE?"] = "changed"

        scope.send = send
        with self.assertRaisesRegex(RuntimeError, "采集状态"):
            self.run_download(scope, entry)
        self.assertEqual(entry["downloaded_points"], 10)
        self.assertNotIn("sha256", entry)


class CleanupTests(unittest.TestCase):
    original = {"SOUR": "CHAN1", "MODE": "NORM", "FORM": "BYTE",
                "STOP": "1400", "STAR": "1"}

    def test_restore_error_is_recorded_not_raised(self):
        metadata = {}
        send = MagicMock(side_effect=OSError("disconnected"))
        with contextlib.redirect_stdout(io.StringIO()):
            restore_transfer(send, self.original, metadata)
        self.assertEqual(metadata["transfer_restore"]["status"], "error")
        self.assertIn("disconnected", metadata["transfer_restore"]["error"])

    def test_no_commands_on_unsafe_stream(self):
        metadata = {}
        send = MagicMock()
        restore_transfer(send, self.original, metadata, safe=False)
        send.assert_not_called()
        self.assertEqual(metadata["transfer_restore"]["status"], "skipped")

    def test_restore_does_not_claim_readback_verification(self):
        metadata = {}
        send = MagicMock()
        restore_transfer(send, self.original, metadata)
        self.assertEqual(metadata["transfer_restore"]["status"], "commands_sent")
        self.assertEqual(send.call_count, 6)

    def test_binary_protocol_errors_are_distinguished(self):
        for payload in (b"", b"not a block", b"#0", b"#210short", b"#11x!"):
            with self.subTest(payload=payload), self.assertRaises(BinaryTransferError):
                block(io.BytesIO(payload), 100000)


class PreambleTests(unittest.TestCase):
    def setUp(self):
        self.scope = FakeScope(points=10)
        self.metadata = {":ACQ:MDEP?": "10", ":ACQ:SRAT?": "1e8",
                         ":TIM:SCAL?": ".002", ":TIM:OFFS?": ".013"}
        self.scope.values.update(self.metadata)

    def prepare(self, entry):
        with patch("capture_key_trial.time.sleep"):
            return prepare_channel(self.scope.send, self.scope.query, 1,
                                   entry, self.metadata)

    def test_stable_raw_matches_recorded_acquisition(self):
        entry = {}
        self.assertEqual(self.prepare(entry), 10)
        self.assertEqual(len(entry["preamble_checks"]), 1)
        self.assertNotIn(":WAV:DATA?", self.scope.commands)

    def test_invalid_first_preamble_recovers_before_data(self):
        original = self.scope.query
        count = 0

        def query(command):
            nonlocal count
            if command == ":WAV:PRE?":
                count += 1
                if count <= 2:
                    return "0,2,0,1,0,0,0,0.04,8,127"
            return original(command)

        self.scope.query = query
        entry = {}
        self.assertEqual(self.prepare(entry), 10)
        self.assertEqual(len(entry["preamble_checks"]), 2)

    def test_display_preamble_never_accepted_as_raw(self):
        self.scope.values[":WAV:PRE?"] = "0,2,1400,1,2e-5,0,0,.04,8,127"
        entry = {}
        with self.assertRaisesRegex(ValueError, "3次未稳定"):
            self.prepare(entry)
        self.assertEqual(len(entry["preamble_checks"]), 3)
        self.assertNotIn(":WAV:DATA?", self.scope.commands)

    def test_changed_acquisition_never_reconfigured(self):
        self.scope.values[":ACQ:SRAT?"] = "2e8"
        with self.assertRaisesRegex(RuntimeError, "已改变"):
            self.prepare({})
        self.assertFalse(self.scope.commands)

    def test_change_during_preamble_settling_is_rejected(self):
        with patch("capture_key_trial.time.sleep", side_effect=lambda _: (
                self.scope.values.update({":TIM:OFFS?": ".014"}))):
            with self.assertRaisesRegex(RuntimeError, "水平设置已改变"):
                prepare_channel(self.scope.send, self.scope.query, 1, {}, self.metadata)
        self.assertNotIn(":WAV:DATA?", self.scope.commands)

    def test_unstable_and_nonfinite_preambles_rejected(self):
        for preamble in ("invalid", "0,2,10,1,nan,0,0,.04,8,127"):
            with self.subTest(preamble=preamble):
                self.scope.values[":WAV:PRE?"] = preamble
                with self.assertRaises(ValueError):
                    self.prepare({})


class CaptureWorkflowTests(unittest.TestCase):
    def capture(self, root, broken=False, diagnostic=False):
        scope = FakeScope(points=10)
        scope.truncated = broken
        scope.values.update({
            "*IDN?": "RIGOL TECHNOLOGIES,DS2202A,DS2D192700914,00.03",
            ":ACQ:MDEP?": "10", ":ACQ:SRAT?": "1e8",
            ":TIM:SCAL?": "0.005", ":TIM:OFFS?": "0.027",
            ":SYST:ERR?": '0,"No error"',
        })
        for channel in (1, 2):
            for name, value in (("SCAL", "1"), ("OFFS", "0"), ("PROB", "1"),
                                ("COUP", "DC"), ("BWL", "20M")):
                scope.values[f":CHAN{channel}:{name}?"] = value
        original_send = scope.send

        def sendall(payload):
            command = payload.decode("ascii").strip()
            if command == ":DISPlay:DATA?":
                scope.stream.seek(0)
                scope.stream.truncate()
                scope.stream.write(b"#16BMmock\n")
                scope.stream.seek(0)
                scope.commands.append(command)
            elif command == ":WAV:DATA?":
                original_send(command)
            elif command.endswith("?"):
                response = scope.query(command).encode() + b"\n"
                scope.stream.seek(0)
                scope.stream.truncate()
                scope.stream.write(response)
                scope.stream.seek(0)
            else:
                original_send(command)
                if command.startswith(":WAV:SOUR "):
                    scope.values[":WAV:SOUR?"] = command.split()[-1]

        sock = MagicMock()
        sock.__enter__.return_value = sock
        sock.makefile.return_value = scope.stream
        sock.sendall.side_effect = sendall
        bitstream = root / "firmware.fs"
        bitstream.write_bytes(b"firmware")
        digest = hashlib.sha256(b"firmware").hexdigest().upper()
        version = {"bitstream_path": str(bitstream), "sha256": digest}
        argv = ["capture_key_trial.py", "--key", "22", "--force", "medium",
                "--trial", "1", "--instrument", "piano", "--volume", "127",
                "--effects", "off", "--bitstream", str(bitstream), "--joint-analysis"]
        output = root / ("firmware_" + digest[:12]) / "K22" / "medium" / "trial_001"
        with patch("sys.argv", argv), \
                patch("capture_key_trial.directory", return_value=root), \
                patch("capture_key_trial.screen_file", return_value=root / "screen.bmp"), \
                patch("capture_key_trial.socket.create_connection", return_value=sock), \
                patch("latency_session.describe_version", return_value=version), \
                patch("latency_spectrum.generate"), \
                contextlib.redirect_stdout(io.StringIO()):
            if diagnostic:
                from verify_scope_download import verify
                output = root / "diagnostic"
                operation = lambda: verify("unused", output)
            else:
                operation = main
            if broken:
                with self.assertRaises(BinaryTransferError):
                    operation()
            else:
                operation()
        return output, scope

    def test_complete_workflow_writes_two_channels_and_screen(self):
        with tempfile.TemporaryDirectory() as temp:
            output, _ = self.capture(Path(temp))
            trial = json.loads((output / "trial.json").read_text(encoding="utf-8"))
            metadata = json.loads((output / "metadata.json").read_text(encoding="utf-8"))
            self.assertEqual(trial["status"], "complete")
            for channel in (1, 2):
                self.assertEqual((output / f"ch{channel}.bin").stat().st_size, 10)
                self.assertEqual(metadata[f"CH{channel}"]["downloaded_points"], 10)
            self.assertEqual((Path(temp) / "screen.bmp").read_bytes(), b"BMmock")
            self.assertEqual(metadata["transfer_restore"]["status"], "commands_sent")

    def test_binary_failure_preserves_incomplete_metadata_without_cleanup_commands(self):
        with tempfile.TemporaryDirectory() as temp:
            output, scope = self.capture(Path(temp), broken=True)
            trial = json.loads((output / "trial.json").read_text(encoding="utf-8"))
            metadata = json.loads((output / "metadata.json").read_text(encoding="utf-8"))
            self.assertEqual(trial["status"], "incomplete")
            self.assertIn("二进制", trial["error_message"])
            self.assertEqual(metadata["transfer_restore"]["status"], "skipped")
            self.assertEqual(metadata["CH1"]["downloaded_points"], 0)
            self.assertEqual(scope.commands[-1], ":WAV:DATA?")
            self.assertFalse((output / "ch2.bin").exists())

    def test_diagnostic_repeats_without_formal_trial(self):
        with tempfile.TemporaryDirectory() as temp:
            output, scope = self.capture(Path(temp), diagnostic=True)
            report = json.loads((output / "report.json").read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "complete")
            self.assertEqual(report["transfer_restore"]["status"], "verified")
            self.assertFalse((output / "trial.json").exists())
            self.assertEqual(len(report["passes"]), 2)
            for channel in ("CH1", "CH2"):
                self.assertEqual(report["passes"][0]["channels"][channel]["sha256"],
                                 report["passes"][1]["channels"][channel]["sha256"])
            self.assertFalse(any("RUN" in c or "SING" in c for c in scope.commands))

    def test_diagnostic_binary_failure_is_not_complete(self):
        with tempfile.TemporaryDirectory() as temp:
            output, scope = self.capture(Path(temp), diagnostic=True, broken=True)
            report = json.loads((output / "report.json").read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "incomplete")
            self.assertEqual(report["transfer_restore"]["status"], "skipped")
            self.assertEqual(scope.commands[-1], ":WAV:DATA?")


if __name__ == "__main__":
    unittest.main()

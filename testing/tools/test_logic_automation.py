from contextlib import nullcontext
import json
import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from logic_automation import acquire, device, detect, wait_single_ready


class LogicTests(unittest.TestCase):
    def manager(self):
        manager = Mock()
        manager.get_devices.return_value = [
            SimpleNamespace(is_simulation=False, device_id="test",
                            device_type=SimpleNamespace(name="LOGIC"))]
        return manager

    def scope(self, states):
        scope = Mock()
        sequence = iter(states)
        values = {
            "*IDN?": "RIGOL TECHNOLOGIES,DS2202A,DS2D192700914,00",
            ":TRIG:MODE?": "EDGE", ":TRIG:EDGE:SOUR?": "CHAN1",
            ":TRIG:EDGE:SLOP?": "NEG", ":TRIG:EDGE:LEV?": "1.5",
        }
        scope.query.side_effect = lambda cmd: next(sequence) if cmd == ":TRIG:STAT?" else values[cmd]
        return scope

    def test_detection_never_captures(self):
        manager = self.manager()
        with patch("logic_automation.connect", return_value=nullcontext(manager)):
            self.assertIn("未启动采集", detect())
        manager.start_capture.assert_not_called()

    def test_simulated_device_rejected(self):
        manager = self.manager()
        manager.get_devices.return_value[0].is_simulation = True
        with self.assertRaises(RuntimeError):
            device(manager)

    def test_joint_order_and_files(self):
        manager, scope = self.manager(), self.scope(["STOP", "WAIT", "WAIT", "STOP"])
        capture = manager.start_capture.return_value
        def export(folder, **_kwargs):
            (Path(folder) / "digital.csv").write_text("test", encoding="utf-8")
        capture.export_raw_data_csv.side_effect = export
        with tempfile.TemporaryDirectory() as tmp, patch("logic_automation.time.sleep"):
            path = acquire("unused", Path(tmp) / "capture",
                           manager_factory=lambda: nullcontext(manager),
                           scope_factory=lambda host: nullcontext(scope), notify=lambda _: None)
            self.assertTrue(path.is_file())
            capture.stop.assert_called_once()
            capture.save_capture.assert_called_once()
            capture.close.assert_called_once()
            scope.send.assert_called_once_with(":SING")

    def test_running_scope_not_taken_over(self):
        manager, scope = self.manager(), self.scope(["RUN"])
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(RuntimeError):
                acquire("unused", Path(tmp) / "capture", manager_factory=lambda: nullcontext(manager),
                        scope_factory=lambda host: nullcontext(scope))
        manager.start_capture.assert_not_called()
        scope.send.assert_not_called()

    def test_premature_trigger_fails_and_stops_owned_capture(self):
        manager, scope = self.manager(), self.scope(["STOP"] * 22)
        with tempfile.TemporaryDirectory() as tmp, patch("logic_automation.time.sleep"):
            with self.assertRaisesRegex(RuntimeError, "始终读到 STOP"):
                acquire("unused", Path(tmp) / "capture", manager_factory=lambda: nullcontext(manager),
                        scope_factory=lambda host: nullcontext(scope))
            data = json.loads((Path(tmp) / "capture/capture.json").read_text(encoding="utf-8"))
            self.assertEqual(data["stage"], "等待示波器进入单次采集")
            self.assertEqual(data["scope_start_states"], ["STOP"] * 21)
        manager.start_capture.return_value.stop.assert_called_once()
        self.assertEqual(scope.send.call_args.args[0], ":STOP")

    def test_initial_stale_stop_is_polled_without_rearming(self):
        manager, scope = self.manager(), self.scope(["STOP", "STOP", "STOP", "WAIT", "WAIT", "STOP"])
        capture = manager.start_capture.return_value
        capture.export_raw_data_csv.side_effect = lambda folder, **kw: (
            Path(folder) / "digital.csv").write_text("test", encoding="utf-8")
        with tempfile.TemporaryDirectory() as tmp, patch("logic_automation.time.sleep"):
            output = Path(tmp) / "capture"
            acquire("unused", output, manager_factory=lambda: nullcontext(manager),
                    scope_factory=lambda host: nullcontext(scope), notify=lambda _: None)
            data = json.loads((output / "capture.json").read_text(encoding="utf-8"))
            self.assertEqual(data["scope_start_states"], ["STOP", "STOP", "WAIT", "WAIT"])
            self.assertEqual(data["status"], "complete")
        scope.send.assert_called_once_with(":SING")

    def test_triggered_before_ready_does_not_prompt_key_press(self):
        manager, scope = self.manager(), self.scope(["STOP", "T'D", "STOP"])
        notify = Mock()
        with tempfile.TemporaryDirectory() as tmp, patch("logic_automation.time.sleep"):
            with self.assertRaisesRegex(RuntimeError, "提示按键前"):
                acquire("unused", Path(tmp) / "capture", manager_factory=lambda: nullcontext(manager),
                        scope_factory=lambda host: nullcontext(scope), notify=notify)
        self.assertFalse(any(call.args[0].startswith("JOINT_READY") for call in notify.call_args_list))
        self.assertEqual([call.args[0] for call in scope.send.call_args_list], [":SING", ":STOP"])

    def test_transient_td_requires_two_waiting_confirmations_without_rearm(self):
        scope = self.scope(["TD", "WAIT", "WAIT"])
        record = dict(scope_start_states=[])
        with patch("logic_automation.time.sleep"):
            wait_single_ready(scope, record, Mock(), Mock())
        self.assertEqual(record["scope_start_states"], ["TD", "WAIT", "WAIT"])
        self.assertEqual(record["startup_ready_confirmations"], 2)
        self.assertTrue(record["startup_td_observed"])
        scope.send.assert_not_called()

    def test_persistent_td_never_becomes_ready(self):
        scope = self.scope(["TD"] * 21)
        with patch("logic_automation.time.sleep"), self.assertRaisesRegex(RuntimeError, "未连续确认"):
            wait_single_ready(scope, dict(scope_start_states=[]), Mock(), Mock())
        scope.send.assert_not_called()

    def test_single_wait_then_td_stop_is_rejected(self):
        scope = self.scope(["WAIT", "TD", "STOP"])
        with patch("logic_automation.time.sleep"), self.assertRaisesRegex(RuntimeError, "按键提示前已结束"):
            wait_single_ready(scope, dict(scope_start_states=[]), Mock(), Mock())

    def test_unknown_or_auto_state_rejected(self):
        for state in ("AUTO", "garbage", ""):
            with self.subTest(state=state), self.assertRaisesRegex(RuntimeError, "未支持"):
                wait_single_ready(self.scope([state]), dict(scope_start_states=[]), Mock(), Mock())

    def test_post_prompt_auto_is_rejected_and_owned_capture_stopped(self):
        manager, scope = self.manager(), self.scope(["STOP", "WAIT", "WAIT", "AUTO"])
        notify = Mock()
        with tempfile.TemporaryDirectory() as tmp, patch("logic_automation.time.sleep"):
            with self.assertRaisesRegex(RuntimeError, "提示按键后"):
                acquire("unused", Path(tmp) / "capture",
                        manager_factory=lambda: nullcontext(manager),
                        scope_factory=lambda host: nullcontext(scope), notify=notify)
        self.assertEqual(scope.send.call_args.args[0], ":STOP")
        self.assertFalse(any(call.args[0].startswith("JOINT_CAPTURED") for call in notify.call_args_list))

    def test_capture_after_transient_td_saves_status_history_and_sends_single_once(self):
        manager, scope = self.manager(), self.scope(["STOP", "TD", "WAIT", "WAIT", "STOP"])
        capture = manager.start_capture.return_value
        capture.export_raw_data_csv.side_effect = lambda folder, **kw: (
            Path(folder) / "digital.csv").write_text("test", encoding="utf-8")
        notify = Mock()
        with tempfile.TemporaryDirectory() as tmp, patch("logic_automation.time.sleep"):
            output = Path(tmp) / "capture"
            acquire("unused", output, manager_factory=lambda: nullcontext(manager),
                    scope_factory=lambda host: nullcontext(scope), notify=notify)
            data = json.loads((output / "capture.json").read_text(encoding="utf-8"))
            self.assertEqual(data["status"], "complete")
            self.assertEqual(data["scope_start_states"], ["TD", "WAIT", "WAIT"])
        scope.send.assert_called_once_with(":SING")
        self.assertEqual(sum(call.args[0].startswith("JOINT_READY") for call in notify.call_args_list), 1)


if __name__ == "__main__":
    unittest.main()

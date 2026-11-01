"""Offline integration checks; no scope connections or real captures."""

from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import instrument_acceptance_gui as gui


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = gui.latency_gui.create_root()
        self.root.withdraw()
        self.app = gui.AcceptanceSuite(
            self.root, settings_path=Path(self.temp.name) / "settings.json")
        firmware = Path(self.temp.name) / "test.fs"
        firmware.write_bytes(b"offline test fixture, not a board image")
        self.app.latency.bitstream.set(str(firmware))
        self.root.update()

    def tearDown(self):
        self.app.dispose()
        self.temp.cleanup()

    def test_timbre_picker_is_readonly_and_preserves_legacy_ids(self):
        page = self.app.latency
        self.assertEqual(str(page.instrument_picker["state"]), "readonly")
        self.assertEqual(tuple(page.instrument_picker["values"]), ("钢琴", "吉他", "编钟"))
        self.assertEqual(gui.latency_gui.instrument_id("bell"), "bianzhong")
        for label, identifier in gui.latency_gui.TIMBRES.items():
            page.instrument.set(label)
            self.assertEqual(gui.latency_gui.instrument_id(page.instrument.get()), identifier)
            self.assertEqual(gui.latency_gui.instrument_id(identifier), identifier)
        page.lock_settings(True)
        self.assertEqual(str(page.instrument_picker["state"]), "disabled")
        page.lock_settings(False)
        self.assertEqual(str(page.instrument_picker["state"]), "readonly")

    def test_slow_progress_check_does_not_block_ui(self):
        import threading
        page = self.app.latency
        page.config = dict(force="medium", joint=True)
        page.conditions = {}
        page.image = Path(self.temp.name)
        page.keys = [1]
        page.targets = {1: 3}
        entered, release = threading.Event(), threading.Event()
        def delayed(*_args):
            entered.set()
            release.wait(2)
            return dict(saved=[1], usable=[1], pending=[], next_number=2)
        with patch.object(gui.latency_gui.session, "analysis_progress", side_effect=delayed):
            start = time.monotonic()
            page.refresh()
            self.assertLess(time.monotonic()-start, .2)
            self.assertTrue(entered.wait(1))
            ticks = []
            self.root.after(0, lambda: ticks.append(True))
            self.root.update()
            self.assertTrue(ticks)
            self.assertTrue(page.busy)
            self.assertEqual(str(page.joint_button["state"]), "disabled")
            release.set()
            deadline = time.monotonic()+3
            while page.busy and time.monotonic() < deadline:
                self.root.update()
                time.sleep(.01)
            self.assertFalse(page.busy)
            self.assertEqual(page.current, (1, 2))
            self.assertIn("even", page.tree.item("1", "tags"))

    def test_plan_background_error_unlocks_settings(self):
        page = self.app.latency
        with patch.object(gui.latency_gui.session, "read_version", side_effect=OSError("fixture")), \
                patch.object(gui.messagebox, "showerror") as error:
            page.start(checked=True)
            deadline = time.monotonic()+3
            while page.busy and time.monotonic() < deadline:
                self.root.update()
                time.sleep(.01)
            self.assertFalse(page.busy)
            self.assertIsNone(page.config)
            self.assertEqual(str(page.instrument_picker["state"]), "readonly")
            error.assert_called_once()

    def test_polyphony_command_uses_bundled_engine(self):
        command = ["pythonw", "-u", str(gui.ROOT / "tools/acceptance_scope.py"),
                   "analyze", "sample"]
        with patch.object(gui.polyphony.AcceptanceApp, "execute") as execute:
            self.app.polyphony.execute(command, "test")
        actual = execute.call_args.args[0]
        self.assertEqual(actual[0], self.app.python)
        self.assertEqual(actual[2], str(gui.VENDOR / "acceptance_scope.py"))
        self.assertEqual(actual[3:], ["analyze", "sample"])

    def test_saved_unverified_is_not_a_capture_failure(self):
        page = self.app.latency
        page.busy = True
        page.config = {"joint": True}
        page.events.put(("saved_unverified", "数据已保存；原因：扫描周期验证未通过"))
        page.root.after_cancel(page.poll_id)
        with patch.object(gui.messagebox, "showwarning") as warning, \
                patch.object(gui.messagebox, "showerror") as error, \
                patch.object(page, "refresh") as refresh:
            page.poll()
        refresh.assert_called_once()
        self.assertFalse(page.busy)
        self.assertEqual(float(page.transfer_bar["value"]), 100)
        self.assertIn("已保存", page.transfer_text.get())
        self.assertIn("联合验证未通过", page.status.get())
        self.assertIn("不能判定", page.status.get())
        warning.assert_called_once()
        self.assertIn("扫描周期", warning.call_args.args[1])
        error.assert_not_called()

    def test_saved_analysis_failure_exposes_message_and_legacy_error(self):
        import json
        folder = Path(self.temp.name)
        path = folder / "latency_analysis_error.json"
        for payload, expected in (
                ({"error": "ValueError('legacy reason')"}, "legacy reason"),
                ({"error": "legacy", "message": "具体分析原因"}, "具体分析原因")):
            path.write_text(json.dumps(payload), encoding="utf-8")
            self.assertIn(expected, gui.latency_gui.saved_analysis_failure(folder))
        path.write_text("not json", encoding="utf-8")
        self.assertIn("运行日志", gui.latency_gui.saved_analysis_failure(folder))

    def test_mutual_exclusion(self):
        with patch.object(gui.messagebox, "showwarning") as warning:
            self.app.polyphony.busy = True
            self.app.latency.save()
            warning.assert_called_once()
            self.app.polyphony.busy = False
        with patch.object(gui.messagebox, "showwarning") as warning:
            self.app.latency.busy = True
            self.app.polyphony.execute([], "test")
            warning.assert_called_once()
            self.app.latency.busy = False

    def test_toolbar_check_does_not_require_stopped_capture(self):
        with patch.object(gui.messagebox, "askokcancel", return_value=True):
            self.app.tabs.select(1)
            self.root.update()
        with patch.object(self.app, "check_async") as check:
            self.app.detect()
        check.assert_called_once_with("latency", require_stop=False)

    def test_latency_check_selects_manual_or_joint_profile(self):
        from scope_preflight import CheckResult
        self.app.latency.ip.set("offline-test")
        for capture_mode, expected in (("自动联合测量", "latency_joint"),
                                       ("手动示波器测量", "latency")):
            self.app.latency.capture_mode.set(capture_mode)
            with patch.object(gui, "inspect_scope", return_value=CheckResult()) as inspect, \
                    patch.object(gui.threading, "Thread") as thread, \
                    patch.object(gui.messagebox, "showinfo"):
                self.app.check_async("latency", require_stop=False)
                thread.call_args.kwargs["target"]()
                self.root.after_cancel(self.app.check_poll_id)
                self.app.poll_checks()
            inspect.assert_called_once_with("offline-test", expected, 1, require_stop=False)

    def test_lrck_read_only_detection_and_download_use_different_stop_policy(self):
        from scope_preflight import CheckResult
        self.app.lrck.ip.set("offline-test")
        with patch("acceptance_extra_pages.inspect_scope", return_value=CheckResult()) as inspect, \
                patch("acceptance_extra_pages.threading.Thread") as thread, \
                patch.object(gui.messagebox, "showinfo"):
            self.app.lrck.detect()
            thread.call_args.kwargs["target"]()
            self.app.lrck.root.after_cancel(self.app.lrck.poll_id)
            self.app.lrck.poll()
            inspect.assert_called_once_with("offline-test", "lrck", 1, require_stop=False)
            inspect.reset_mock()
            self.app.lrck.check("offline-test", 2)
            inspect.assert_called_once_with("offline-test", "lrck", 2)

    def test_switch_requires_confirmation(self):
        with patch.object(gui.messagebox, "askokcancel", return_value=False):
            self.app.tabs.select(1)
            self.root.update()
        self.assertEqual(self.app.tabs.index(self.app.tabs.select()), 0)
        with patch.object(gui.messagebox, "askokcancel", return_value=True):
            self.app.tabs.select(1)
            self.root.update()
        self.assertEqual(self.app.tabs.index(self.app.tabs.select()), 1)

    def test_switch_blocked_while_busy(self):
        self.app.polyphony.busy = True
        with patch.object(gui.messagebox, "showwarning"):
            self.app.tabs.select(1)
            self.root.update()
        self.assertEqual(self.app.tabs.index(self.app.tabs.select()), 0)
        self.app.polyphony.busy = False

    def test_latency_plan_and_stop_gate(self):
        self.app.latency.select(range(4))
        self.app.latency.instrument.set("吉他")
        with patch.object(gui.latency_gui.session, "read_version", return_value="A" * 64), \
                patch.object(gui.latency_gui.session, "analysis_progress",
                             return_value=dict(saved=[1, 2], usable=[1], pending=[2], next_number=3)), \
                patch.object(gui.messagebox, "askokcancel", return_value=True) as confirm:
            self.app.latency.start(checked=True)
            deadline = time.monotonic() + 3
            while self.app.latency.busy and time.monotonic() < deadline:
                self.root.update()
                time.sleep(.01)
        text = confirm.call_args.args[1]
        self.assertIn("K1：已可用 1 次 / 目标 3 次 / 还需 2 次", text)
        self.assertIn("共 8 条分析可用记录", text)
        self.assertNotIn("分析可用目标 3", text)
        self.assertEqual(self.app.latency.config["bitstream"], self.app.latency.bitstream.get())
        self.assertEqual(self.app.latency.config["instrument"], "guitar")
        self.assertEqual(self.app.latency.conditions["instrument_user_reported"], "guitar")
        self.assertEqual(self.app.latency.current, (1, 3))
        values = self.app.latency.tree.item("1", "values")
        self.assertEqual(str(values[1]), "2")
        self.assertEqual(str(values[2]), "1")
        self.assertEqual(str(values[3]), "1")
        self.assertFalse(self.app.latency.config["joint"])
        self.assertTrue(all(str(radio["state"]) == "disabled" for radio in self.app.latency.capture_modes))
        self.assertEqual(str(self.app.latency.save_button["state"]), "disabled")
        self.app.latency.stopped.set(True)
        self.app.latency.update_save()
        self.assertEqual(str(self.app.latency.save_button["state"]), "normal")

    def test_joint_arming_updates_status_without_prompting_key(self):
        page = self.app.latency
        page.events.put(("joint_arming", "JOINT_ARMING 继续观察同一次 SINGLE，先不要按键"))
        page.root.after_cancel(page.poll_id)
        with patch.object(gui.latency_gui, "PressPrompt") as prompt:
            page.poll()
            prompt.assert_not_called()
        self.assertIn("先不要按键", page.status.get())
        self.assertEqual(page.transfer_text.get(), "确认启动状态，请勿按键")

    def test_joint_ready_shows_target_without_blocking_and_capture_closes_it(self):
        app = self.app.latency
        app.current = (7, 1)
        app.events.put(("joint_ready", "JOINT_READY 两台仪器已开始记录"))
        app.root.after_cancel(app.poll_id)
        app.poll()
        self.root.update_idletasks()
        prompt = app.press_prompt
        self.assertIsNotNone(prompt)
        self.assertIn("15", prompt.remaining.get())
        labels = [str(widget.cget("text")) for widget in prompt.window.winfo_children()
                  if isinstance(widget, gui.tk.Label)]
        self.assertIn("现在按一次 K7", labels)
        self.assertIsNone(prompt.window.grab_current())
        app.events.put(("joint_captured", "JOINT_CAPTURED 已停止"))
        app.root.after_cancel(app.poll_id)
        app.poll()
        self.assertIsNone(app.press_prompt)
        self.assertIn("请勿再次按键", app.status.get())

    def test_press_prompt_clears_with_plan_display(self):
        app = self.app.latency
        app.press_prompt = gui.latency_gui.PressPrompt(app.root, 1)
        app.clear_display()
        self.assertIsNone(app.press_prompt)

    def test_polyphony_result_display(self):
        app = self.app.polyphony
        app.output_lines = ['{"spectral_check":"PASS","matched_enabled_peaks":64,'
                            '"expected_peaks":64,"unexpected_enabled_targets":0}']
        app.finished(0)
        self.assertEqual(app.metrics[0].get(), "64")
        self.assertEqual(app.metrics[2].get(), "0")

    def test_actual_transfer_progress(self):
        app = self.app.polyphony
        app.append("250000/1000000 points\n")
        self.assertEqual(float(app.progress["value"]), 250000)
        self.assertEqual(float(app.progress["maximum"]), 1000000)
        self.assertIn("25.0%", app.download_text.get())
        app.append("1000000/1000000 points\n")
        self.assertIn("频谱分析", app.status.get())
        latency = self.app.latency
        latency.events.put(("transfer", "TRANSFER 2 250000 1000000"))
        latency.root.after_cancel(latency.poll_id)
        latency.poll()
        self.assertEqual(float(latency.transfer_bar["value"]), 62.5)
        self.assertIn("62.5%", latency.transfer_text.get())

    def test_screen_link_uses_saved_trial_and_logs_exact_path(self):
        folder = Path(self.temp.name) / "trial"
        folder.mkdir()
        (folder / "screen.bmp").write_bytes(b"BM")
        page = self.app.latency
        page.events.put(("folder_ready", str(folder)))
        page.root.after_cancel(page.poll_id)
        page.poll()
        self.assertEqual(page.latest_folder, folder)
        self.assertIn(str(folder / "screen.bmp"), page.log.get("1.0", "end"))
        with patch.object(gui.os, "startfile") as open_file, \
                patch("measurement_files.filedialog.askopenfilename", return_value=str(folder / "screen.bmp")):
            page.open_screen()
            open_file.assert_called_once_with(folder / "screen.bmp")
        with patch.object(gui.os, "startfile") as open_folder:
            page.open_trial()
            open_folder.assert_called_once_with(folder)

    def test_scan_review_updates_shared_report_and_trial(self):
        trial = Path(self.temp.name) / "trial"
        report = trial / "scan_validation/verification_001/report.html"
        report.parent.mkdir(parents=True)
        report.write_text("test", encoding="utf-8")
        spectrum = trial / "audio_spectrum.png"
        spectrum.write_bytes(b"test")
        self.app.scan.events.put(("done", str(report)))
        self.app.scan.root.after_cancel(self.app.scan.poll_id)
        self.app.scan.poll()
        self.assertEqual(self.app.latency.latest_report, report)
        self.assertEqual(self.app.latency.latest_folder, trial)
        self.assertEqual(self.app.latency.latest_spectrum, spectrum)
        with patch.object(gui.os, "startfile") as open_file, \
                patch("measurement_files.filedialog.askopenfilename", return_value=str(report)):
            self.app.latency.open_report()
            open_file.assert_called_once_with(report)
        with patch.object(gui.os, "startfile") as open_file:
            self.app.latency.open_folder()
            open_file.assert_called_once_with(gui.latency_gui.session.BASE)


    def test_failed_result_lists_all_known_reasons(self):
        app = self.app.polyphony
        app.output_lines = ['{"spectral_check":"FAIL","matched_enabled_peaks":64,'
                            '"expected_peaks":64,"unexpected_enabled_targets":0,'
                            '"clipped":true,"clock_fit_at_boundary":false,'
                            '"largest_non_target_db":18.033193}']
        app.finished(2)
        text = app.detail.get()
        self.assertIn("未通过原因", text)
        self.assertIn("削顶", text)
        self.assertIn("+18.03", text)
        self.assertNotIn("目标谱峰不足", text)

    def test_end_clears_view_not_saved_data(self):
        app = self.app.latency
        app.tree.insert("", "end", values=("K1", 2, 3, "待测"))
        app.log_message("old run")
        app.end()
        self.assertFalse(app.tree.get_children())
        self.assertEqual(app.log.get("1.0", "end").strip(), "")
        self.assertIn("请选择", app.key_label.get())

    def test_disconnected_start_cannot_create_plan(self):
        app = self.app.latency
        with patch.object(gui.latency_gui, "inspect_scope", side_effect=OSError("offline")), \
                patch.object(gui.messagebox, "showerror") as error:
            app.start()
            deadline = time.monotonic() + 3
            while app.busy and time.monotonic() < deadline:
                self.root.update()
                time.sleep(.02)
            self.assertFalse(app.busy)
            self.assertIsNone(app.config)
            self.assertFalse(app.tree.get_children())
            error.assert_called()

    def test_polyphony_capture_is_gated(self):
        with patch.object(self.app, "check_async") as gate, \
                patch.object(gui.polyphony.AcceptanceApp, "execute") as execute:
            self.app.polyphony.execute(["python", "acceptance_scope.py", "capture"], "capture")
        gate.assert_called_once()
        execute.assert_not_called()

    def test_four_pages_and_lrck_stop_gate(self):
        self.assertEqual(len(self.app.tabs.tabs()), 4)
        self.assertFalse(hasattr(self.app, "latency_tabs"))
        self.assertEqual(self.app.scan.root, self.app.latency.joint_settings)
        self.assertIs(self.app.scan.log, self.app.latency.log)
        self.assertIs(self.app.scan.progress, self.app.latency.transfer_bar)
        with patch.object(gui.messagebox, "showwarning") as warning, \
                patch.object(self.app.lrck, "run") as run:
            self.app.lrck.capture()
            warning.assert_called_once()
            run.assert_not_called()

    def test_scan_requires_inputs_and_shares_busy_lock(self):
        with patch("scan_validation_page.messagebox.showerror") as error, \
                patch.object(self.app.scan, "run") as run:
            self.app.scan.analyze()
            error.assert_called_once()
            run.assert_not_called()
        self.app.scan.busy = True
        self.assertTrue(self.app.any_busy())
        with patch.object(gui.messagebox, "showwarning"):
            self.app.detect()
        self.app.scan.busy = False

    def test_joint_offline_report_refreshes_active_analysis_counts(self):
        page = self.app.latency
        page.config = {"joint": True}
        path = Path(self.temp.name)/"scan_validation/verification_001/report.html"
        with patch.object(page, "refresh") as refresh:
            self.app.scan.report_ready(path)
        refresh.assert_called_once()
        self.assertEqual(page.latest_report, path)

    def test_joint_requires_plan_and_error_budget(self):
        with patch.object(gui.messagebox, "showwarning") as warning:
            self.app.latency.joint_start()
            warning.assert_called_once()
        self.app.latency.config = {"ip": "unused"}
        self.app.latency.current = (1, 1)
        with patch.object(gui.messagebox, "showerror") as error:
            self.app.latency.joint_start()
            error.assert_called_once()
        self.app.scan.margin.set("30")
        self.app.scan.ppm.set("25")
        self.app.scan.confirm.set(True)
        with patch.object(gui.messagebox, "askokcancel", return_value=True), \
                patch.object(self.app, "check_async") as check:
            self.app.latency.joint_start()
            check.assert_called_once()
        self.app.latency.config = None
        self.app.latency.current = None

    def test_logic_detection_does_not_create_report(self):
        self.app.scan.events.put(("checked", "真实设备已连接；未启动采集"))
        self.app.scan.root.after_cancel(self.app.scan.poll_id)
        self.app.scan.poll()
        self.assertIsNone(self.app.scan.latest_report)
        self.assertIn("未启动采集", self.app.scan.status.get())

    def test_scan_settings_have_no_duplicate_capture_entry(self):
        page = self.app.scan
        self.assertFalse(page.offline_toggle.get())
        self.assertFalse(hasattr(page, "auto_button"))
        self.assertFalse(hasattr(page, "start_joint"))
        self.assertEqual(page.offline.winfo_manager(), "")
        self.assertEqual(page.advanced.winfo_manager(), "")
        self.assertEqual(page.column_fields.winfo_manager(), "")
        page.offline_toggle.set(True)
        page.set_mode()
        self.root.update_idletasks()
        self.assertEqual(page.offline.winfo_manager(), "pack")
        self.assertGreater(page.offline.winfo_reqheight(), 100)
        self.assertGreater(self.app.latency.offline_host.winfo_reqheight(), 100)
        self.assertEqual(page.offline_button.winfo_manager(), "pack")
        page.advanced_toggle.set(True)
        page.set_mode()
        self.assertEqual(page.advanced.winfo_manager(), "pack")
        page.column_toggle.set(True)
        page.set_mode()
        self.assertEqual(page.column_fields.winfo_manager(), "grid")

    def test_manual_mode_hides_joint_settings_unless_review_is_open(self):
        latency, scan = self.app.latency, self.app.scan
        latency.capture_mode.set("手动示波器测量")
        latency.switch_capture_mode()
        self.assertEqual(scan.page.winfo_manager(), "")
        scan.offline_toggle.set(True)
        scan.set_mode()
        self.assertEqual(scan.page.winfo_manager(), "pack")
        scan.offline_toggle.set(False)
        scan.set_mode()
        self.assertEqual(scan.page.winfo_manager(), "")
        latency.capture_mode.set("自动联合测量")
        latency.switch_capture_mode()
        self.assertEqual(scan.page.winfo_manager(), "pack")

    def test_inline_review_locks_measurement_until_finished(self):
        page = self.app.scan
        with patch("acceptance_extra_pages.threading.Thread") as thread:
            page.run(lambda: "offline", report=False)
            thread.assert_called_once()
        self.assertTrue(page.busy)
        self.assertEqual(str(self.app.latency.joint_button["state"]), "disabled")
        self.assertEqual(str(self.app.latency.start_button["state"]), "disabled")
        with patch.object(gui.messagebox, "showwarning") as warning:
            self.app.latency.end()
            warning.assert_called_once()
        page.events.put(("checked", "离线检查完成"))
        page.root.after_cancel(page.poll_id)
        page.poll()
        self.assertFalse(page.busy)
        self.assertEqual(str(self.app.latency.start_button["state"]), "normal")

    def test_offline_review_requires_same_press_confirmation(self):
        page = self.app.scan
        trial = Path(self.temp.name) / "trial"
        trial.mkdir()
        (trial / "trial.json").write_text("{}")
        source = trial / "digital.csv"
        source.write_text("fixture")
        page.trial.set(str(trial))
        page.csv.set(str(source))
        page.confirm.set(True)
        with patch.object(gui.messagebox, "showerror") as error, patch.object(page, "run") as run:
            page.analyze()
        error.assert_called_once()
        run.assert_not_called()

    def test_capture_mode_shows_only_relevant_controls(self):
        page = self.app.latency
        self.assertEqual(page.capture_mode.get(), "手动示波器测量")
        self.assertEqual(page.manual_capture.winfo_manager(), "pack")
        self.assertEqual(page.joint_capture.winfo_manager(), "")
        page.stopped.set(True)
        page.capture_mode.set("自动联合测量")
        page.switch_capture_mode()
        self.assertFalse(page.stopped.get())
        self.assertEqual(page.manual_capture.winfo_manager(), "")
        self.assertEqual(page.joint_capture.winfo_manager(), "pack")
        page.busy = True
        page.update_save()
        self.assertTrue(all(str(radio["state"]) == "disabled" for radio in page.capture_modes))
        page.busy = False

    def test_wiring_prompt_resets_confirmation_on_key_change(self):
        page = self.app.latency
        page.config = dict(joint=True)
        page.show_wiring(1)
        self.app.scan.confirm.set(True)
        page.show_wiring(1)
        self.assertTrue(self.app.scan.confirm.get())
        page.show_wiring(7)
        self.assertFalse(self.app.scan.confirm.get())
        self.assertIn("D0、D1 换到当前 A/B 行", page.connection.get())
        self.assertIn("C15", page.connection.get())
        self.assertIn("C14", page.connection.get())
        self.assertIn("B16", page.connection.get())
        page.config = dict(joint=False)
        page.show_wiring(13)
        self.assertIn("测量接线不变", page.connection.get())
        self.assertNotIn("D0、D1 换到", page.connection.get())

    def test_joint_allows_unbudgeted_capture_without_claim(self):
        self.app.latency.config = {"ip": "unused"}
        self.app.latency.current = (1, 1)
        self.app.scan.confirm.set(True)
        with patch.object(gui.messagebox, "askokcancel", return_value=True), \
                patch.object(self.app, "check_async") as check:
            self.app.latency.joint_start()
            check.assert_called_once()
        self.app.latency.config = None
        self.app.latency.current = None

    def test_extra_pages_share_busy_lock(self):
        self.app.lrck.busy = True
        with patch.object(gui.messagebox, "showwarning"), \
                patch.object(gui.polyphony.AcceptanceApp, "execute") as execute:
            self.app.polyphony.execute([], "test")
            execute.assert_not_called()
            self.app.latency.start(checked=True)
            self.assertIsNone(self.app.latency.config)
        self.app.lrck.busy = False
        self.app.latency.busy = True
        with patch.object(gui.messagebox, "showwarning"), \
                patch.object(gui.threading, "Thread") as thread:
            self.app.evidence.run(lambda: "should not run")
            thread.assert_not_called()
        self.app.latency.busy = False

    def test_lrck_detect_does_not_mark_a_measurement_complete(self):
        from scope_preflight import CheckResult
        self.app.lrck.busy = True
        self.app.lrck.events.put(("detected", CheckResult()))
        self.app.lrck.root.after_cancel(self.app.lrck.poll_id)
        with patch.object(gui.messagebox, "showinfo"):
            self.app.lrck.poll()
        self.assertFalse(self.app.lrck.busy)
        self.assertIsNone(self.app.lrck.latest_report)
        self.assertIn("未采集", self.app.lrck.status.get())

    def test_font_sizes_and_small_window_scrolling(self):
        style = gui.ttk.Style(self.root)
        self.app.font_size.set("大")
        self.app.configure_style()
        self.assertIn("14", str(style.lookup("TLabel", "font")))
        self.assertEqual(self.app.polyphony.saved["ui_font_size"], "大")
        self.root.deiconify()
        self.root.geometry("960x700")
        with patch.object(gui.messagebox, "askokcancel", return_value=True):
            self.app.tabs.select(1)
            self.root.update()
        page = self.app.latency_scroll
        self.assertGreater(page.body.winfo_reqheight(), page.canvas.winfo_height())
        page.canvas.yview_moveto(1)
        self.root.update()
        self.assertGreater(page.canvas.yview()[0], 0)
        self.assertAlmostEqual(page.canvas.yview()[1], 1, places=2)
        self.assertEqual(len(self.app.latency.result_tabs.tabs()), 2)

    def test_typed_file_buttons_and_fixed_output_roots(self):
        from measurement_files import directory
        self.assertEqual(Path(self.app.polyphony.fields["output"].get()), directory("raw", "polyphony"))
        self.assertEqual(Path(self.app.lrck.output.get()), directory("raw", "lrck"))
        self.assertEqual(Path(self.app.evidence.output.get()), directory("reports", "evidence"))
        self.assertEqual(len(self.app.polyphony.action_buttons), 6)
        self.assertEqual(len(self.app.lrck.action_buttons), 4)
        self.assertEqual(len(self.app.evidence.action_buttons), 2)
        self.assertIn("下载 STOP", self.app.polyphony.action_buttons[0].cget("text"))
        self.assertIn("证据汇总", self.app.evidence.action_buttons[0].cget("text"))

    def test_evidence_inputs_route_to_different_raw_kinds(self):
        with patch("acceptance_extra_pages.pick_record", return_value=None) as choose:
            self.app.evidence.browse_record(self.app.evidence.lrck, "lrck")
            self.assertEqual(choose.call_args.args[1], "lrck")
            self.app.evidence.browse_record(self.app.evidence.poly, "polyphony")
            self.assertEqual(choose.call_args.args[1], "polyphony")
            self.assertTrue(choose.call_args.kwargs["all_voices"])

    def test_file_chooser_cancel_never_starts_analysis(self):
        with patch("latency_gui.pick_record", return_value=None), \
                patch("latency_gui.threading.Thread") as thread:
            self.app.latency.analyze_saved()
            thread.assert_not_called()
        with patch("acceptance_extra_pages.pick_record", return_value=None), \
                patch.object(self.app.lrck, "run") as run:
            self.app.lrck.analyze_saved()
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()

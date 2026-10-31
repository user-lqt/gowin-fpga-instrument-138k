"""GUI regression with synthetic CLI messages only; never contacts a scope."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import time
import tkinter as tk
from PIL import ImageGrab

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("acceptance_gui", ROOT / "tools/acceptance_gui.py")
gui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gui)


def pump(window, predicate, timeout=10):
    end = time.monotonic()+timeout
    while not predicate():
        window.update()
        if time.monotonic() > end:
            raise AssertionError("GUI event timeout")
        time.sleep(.02)
    window.update()


def main():
    gui.configure_dpi()
    with tempfile.TemporaryDirectory() as directory:
        settings = Path(directory) / "settings.json"
        window = tk.Tk()
        app = gui.AcceptanceApp(window, settings)
        window.update()
        assert len(app.selection_box["values"]) == 69
        app.selection_box.current(68)
        app.select_changed()
        assert app.fields["selection"].get() == "68"
        assert "6659.18" in app.selection_info.get()
        app.fields["voices"].set("32")
        app.refresh_selections()
        assert app.fields["selection"].get() == "0"
        assert len(app.selection_box["values"]) == 37
        app.selection_box.current(36)
        app.select_changed()
        assert "3659.18" in app.selection_info.get()
        app.fields["ip"].set("192.168.1.100")
        app.save_settings()
        assert json.loads(settings.read_text(encoding="utf-8"))["ip"] == "192.168.1.100"
        result = dict(spectral_check="PASS", matched_enabled_peaks=31,
                      expected_peaks=31, unexpected_enabled_targets=0,
                      sample_rate_hz=1000000, record_seconds=.524288,
                      clipped=False, clock_fit_at_boundary=False)
        # Exercise worker queue, result parsing, controls and report-path tracking.
        command = [sys.executable, "-c",
                   "import json; print('Report: C:/test/report.html'); print(" +
                   repr(json.dumps(result, indent=2)) + ")"]
        app.execute(command, "界面回归测试")
        pump(window, lambda: not app.busy)
        assert app.verdict.get() == "检测通过"
        assert [v.get() for v in app.metrics] == ["31", "31", "0"]
        assert str(app.latest_report).replace("\\", "/") == "C:/test/report.html"
        assert str(app.selection_box.cget("state")) == "readonly"
        result["spectral_check"] = "FAIL"
        app.output_lines = [json.dumps(result, indent=2)]
        app.finished(2)
        assert app.verdict.get() == "检测未通过"
        app.output_lines = ["Traceback: simulated failure"]
        app.finished(1)
        assert app.verdict.get() == "运行失败"
        comparison = dict(comparison="PASS", common_gain_change_db=-1.97,
                          rows=[dict(match=True), dict(match=True)])
        app.output_lines = [json.dumps(comparison, indent=2)]
        app.finished(0)
        assert app.metric_titles[0].get() == "对比通过路数"
        assert app.metrics[0].get() == "2"
        app.fields["voices"].set("64")
        app.fields["selection"].set("0")
        app.refresh_selections()
        # Screenshot is explicitly labelled test data in the live window.
        result.update(spectral_check="PASS", matched_enabled_peaks=64, expected_peaks=64)
        app.output_lines = [json.dumps(result)]
        app.finished(0)
        app.status.set("界面回归测试 · 示例结果，非本次硬件测量")
        app.fields["bitstream"].set("C:/FPGA/instrument_64.fs")
        window.geometry("1040x860+80+80")
        window.lift()
        window.attributes("-topmost", True)
        window.update()
        time.sleep(.3)
        window.update()
        output = ROOT / "verification/acceptance_gui_chinese.png"
        ImageGrab.grab(bbox=(window.winfo_rootx(), window.winfo_rooty(),
                            window.winfo_rootx()+window.winfo_width(),
                            window.winfo_rooty()+window.winfo_height())).save(output)
        assert app.selection_box.winfo_width() > 250
        app.close()
        window = tk.Tk()
        restored = gui.AcceptanceApp(window, settings)
        assert restored.fields["ip"].get() == "192.168.1.100"
        assert restored.fields["voices"].get() == "64"
        restored.close()
        print("PASS Chinese GUI: selection mapping, persistence, worker queue, PASS/FAIL/error, comparison, screenshot")


if __name__ == "__main__":
    main()

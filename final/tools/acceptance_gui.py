"""Chinese desktop launcher; capture and FFT algorithms remain in the CLI."""
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

ROOT = Path(__file__).resolve().parents[1]


def configure_dpi():
    if sys.platform == "win32":
        import ctypes
        ctypes.windll.user32.SetProcessDPIAware()


def selection_labels(voices):
    return (["全部开启（ALL）"] +
            [f"第 {group} 组（GROUP {group:02d}）" for group in range(1, 5)] +
            [f"关闭第 {voice:02d} 路（MUTE {voice:02d}）" for voice in range(1, voices+1)])


def last_result(text):
    decoder = json.JSONDecoder()
    starts = []
    offset = 0
    for line in text.splitlines(keepends=True):
        if line.startswith("{"):
            starts.append(offset)
        offset += len(line)
    for start in reversed(starts):
        try:
            value, _ = decoder.raw_decode(text[start:])
            if isinstance(value, dict):
                return value
        except ValueError:
            pass
    return {}


class AcceptanceApp:
    def __init__(self, window, settings_path=None):
        self.window = window
        identity = hashlib.sha256(str(ROOT).encode()).hexdigest()[:12]
        self.settings_path = Path(settings_path) if settings_path else (
            Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) /
            "GowinPolyphony" / f"scope_{identity}.json")
        try:
            saved = json.loads(self.settings_path.read_text(encoding="utf-8"))
            if not isinstance(saved, dict):
                saved = {}
        except (OSError, ValueError):
            saved = {}
        self.saved = saved
        self.busy = False
        self.events = queue.Queue()
        self.latest_report = None
        self.output_lines = []
        self.operation = ""
        defaults = dict(ip="", channel="1", voices="64", selection="0",
                        bitstream="", output=str(ROOT / "measurements"))
        self.fields = {key: tk.StringVar(value=str(saved.get(key, default)))
                       for key, default in defaults.items()}
        for key, options in (("channel", ("1", "2")), ("voices", ("32", "64"))):
            if self.fields[key].get() not in options:
                self.fields[key].set(options[-1])
        self.selection_text = tk.StringVar()
        self.selection_info = tk.StringVar()
        self.status = tk.StringVar(value="就绪")
        self.verdict = tk.StringVar(value="尚无检测结果")
        self.metrics = [tk.StringVar(value="—") for _ in range(3)]
        self.metric_titles = [tk.StringVar(value=title) for title in
                              ("检出的目标谱峰", "期望谱峰", "异常目标谱峰")]
        self.detail = tk.StringVar(value="等待采集或载入已有数据")
        window.title("32/64 复音验收 · 示波器采集")
        window.geometry("1040x860")
        window.minsize(960, 820)
        window.configure(background="#f5f6f7")
        window.columnconfigure(0, weight=1)
        window.rowconfigure(0, weight=1)
        style = ttk.Style(window)
        style.theme_use("clam")
        style.configure(".", font=("Microsoft YaHei UI", 10))
        style.configure("TFrame", background="#f5f6f7")
        style.configure("TLabel", background="#f5f6f7", foreground="#242a30")
        style.configure("Title.TLabel", font=("Microsoft YaHei UI", 18, "bold"))
        style.configure("Muted.TLabel", foreground="#626c76")
        style.configure("Metric.TLabel", font=("Microsoft YaHei UI", 18, "bold"))
        style.configure("TButton", padding=(12, 7))
        style.configure("Primary.TButton", background="#17675c", foreground="white")
        style.map("Primary.TButton", background=[("active", "#105347"),
                                                ("disabled", "#899d98")])
        style.configure("TLabelframe", background="#f5f6f7")
        style.configure("TLabelframe.Label", background="#f5f6f7",
                        foreground="#4b565f", font=("Microsoft YaHei UI", 10, "bold"))
        panel = ttk.Frame(window, padding=20)
        panel.grid(sticky="nsew")
        panel.columnconfigure(0, weight=1)
        panel.rowconfigure(4, weight=1)
        header = ttk.Frame(panel)
        header.grid(row=0, column=0, sticky="ew", pady=(0, 16))
        header.columnconfigure(0, weight=1)
        ttk.Label(header, text="复音现场验收", style="Title.TLabel").grid(sticky="w")
        ttk.Label(header, text="DS2202A  /  DAC 输出频谱",
                  style="Muted.TLabel").grid(row=0, column=1, sticky="e")
        self.controls = []
        setup = ttk.LabelFrame(panel, text="采集设置", padding=12)
        setup.grid(row=1, column=0, sticky="ew")
        setup.columnconfigure(1, weight=3)
        setup.columnconfigure(3, weight=1)
        for row, label in enumerate(("示波器 IP", "复音版本", "测试状态")):
            ttk.Label(setup, text=label).grid(row=row, column=0, sticky="w", padx=(0, 12), pady=5)
        self.add_control(ttk.Entry(setup, textvariable=self.fields["ip"])).grid(
            row=0, column=1, sticky="ew", pady=5)
        ttk.Label(setup, text="采集通道").grid(row=0, column=2, padx=(24, 12))
        self.add_control(ttk.Combobox(
            setup, textvariable=self.fields["channel"], values=("1", "2"),
            width=10, state="readonly"), True).grid(row=0, column=3, sticky="ew")
        voices = self.add_control(ttk.Combobox(
            setup, textvariable=self.fields["voices"], values=("32", "64"),
            state="readonly"), True)
        voices.grid(row=1, column=1, sticky="ew", pady=5)
        voices.bind("<<ComboboxSelected>>", self.refresh_selections)
        self.selection_box = self.add_control(ttk.Combobox(
            setup, textvariable=self.selection_text, state="readonly"), True)
        self.selection_box.grid(row=2, column=1, sticky="ew", pady=5)
        self.selection_box.bind("<<ComboboxSelected>>", self.select_changed)
        ttk.Label(setup, textvariable=self.selection_info,
                  style="Muted.TLabel", wraplength=310).grid(
                      row=2, column=2, columnspan=3, padx=(24, 0), sticky="w")
        ttk.Label(setup, text="已下载的 .fs").grid(row=3, column=0, sticky="w", padx=(0, 12), pady=5)
        self.add_control(ttk.Entry(setup, textvariable=self.fields["bitstream"])).grid(
            row=3, column=1, columnspan=3, sticky="ew", pady=5, padx=(0, 8))
        self.add_control(ttk.Button(setup, text="选择文件", command=self.browse_bitstream)).grid(
            row=3, column=4, sticky="e")
        ttk.Label(setup, text="数据保存目录").grid(row=4, column=0, sticky="w", padx=(0, 12), pady=5)
        self.add_control(ttk.Entry(setup, textvariable=self.fields["output"])).grid(
            row=4, column=1, columnspan=3, sticky="ew", pady=5, padx=(0, 8))
        self.add_control(ttk.Button(setup, text="选择目录", command=self.browse_output)).grid(
            row=4, column=4, sticky="e")
        actions = ttk.Frame(panel)
        actions.grid(row=2, column=0, sticky="ew", pady=12)
        self.add_control(ttk.Button(actions, text="采集并分析", style="Primary.TButton",
                                   command=self.capture)).pack(side="left")
        self.add_control(ttk.Button(actions, text="分析已有数据",
                                   command=self.replay)).pack(side="left", padx=8)
        self.add_control(ttk.Button(actions, text="全开 / 单路静音对比",
                                   command=self.compare)).pack(side="left")
        ttk.Button(actions, text="打开最新报告", command=self.open_report).pack(side="right")
        strip = ttk.Frame(panel)
        strip.grid(row=3, column=0, sticky="ew", pady=(0, 10))
        ttk.Label(strip, textvariable=self.status, style="Muted.TLabel").pack(side="left")
        self.progress = ttk.Progressbar(strip, mode="indeterminate", length=180)
        self.progress.pack(side="right")
        tabs = ttk.Notebook(panel)
        tabs.grid(row=4, column=0, sticky="nsew")
        results = ttk.Frame(tabs, padding=16)
        tabs.add(results, text="检测结果")
        log_panel = ttk.Frame(tabs)
        tabs.add(log_panel, text="运行日志")
        self.verdict_label = ttk.Label(results, textvariable=self.verdict, style="Metric.TLabel")
        self.verdict_label.pack(anchor="w", pady=(0, 16))
        metrics = ttk.Frame(results)
        metrics.pack(fill="x", pady=(0, 16))
        for col, title in enumerate(self.metric_titles):
            metrics.columnconfigure(col, weight=1, uniform="metric")
            item = ttk.Frame(metrics)
            item.grid(row=0, column=col, sticky="ew")
            ttk.Label(item, textvariable=title, style="Muted.TLabel").pack(anchor="w")
            ttk.Label(item, textvariable=self.metrics[col], style="Metric.TLabel").pack(anchor="w")
        ttk.Label(results, textvariable=self.detail, justify="left", wraplength=780).pack(anchor="w")
        log_panel.columnconfigure(0, weight=1)
        log_panel.rowconfigure(0, weight=1)
        self.log = tk.Text(log_panel, state="disabled", wrap="word", relief="flat",
                           background="#ffffff", foreground="#303840",
                           font=("Microsoft YaHei UI", 10), padx=12, pady=12)
        self.log.grid(row=0, column=0, sticky="nsew")
        scroll = ttk.Scrollbar(log_panel, command=self.log.yview)
        scroll.grid(row=0, column=1, sticky="ns")
        self.log.configure(yscrollcommand=scroll.set)
        window.protocol("WM_DELETE_WINDOW", self.close)
        self.refresh_selections()
        self.poll_id = window.after(80, self.poll)

    def add_control(self, control, readonly=False):
        self.controls.append((control, "readonly" if readonly else "normal"))
        return control

    def refresh_selections(self, _event=None):
        labels = selection_labels(int(self.fields["voices"].get()))
        try:
            index = int(self.fields["selection"].get())
        except ValueError:
            index = 0
        index = index if 0 <= index < len(labels) else 0
        self.selection_box.configure(values=labels)
        self.selection_box.current(index)
        self.select_changed()

    def select_changed(self, _event=None):
        index = self.selection_box.current()
        voices = int(self.fields["voices"].get())
        self.fields["selection"].set(str(index))
        expected = voices if index == 0 else voices//4 if index <= 4 else voices-1
        text = f"编号 {index} · 期望 {expected} 路"
        if index >= 5:
            hz = (257+32*(index-5))*48000/16384
            text += f" · 关闭 {hz:.2f} Hz"
        self.selection_info.set(text)

    def save_settings(self):
        self.saved.update({key: value.get() for key, value in self.fields.items()})
        try:
            self.settings_path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.settings_path.with_suffix(".tmp")
            temporary.write_text(json.dumps(self.saved, ensure_ascii=False, indent=2), encoding="utf-8")
            temporary.replace(self.settings_path)
        except OSError as error:
            self.append(f"设置保存失败：{error}\n")

    def browse_bitstream(self):
        filename = filedialog.askopenfilename(
            title="选择板上已下载的 FPGA 文件",
            initialdir=str(Path(self.fields["bitstream"].get()).parent),
            filetypes=[("高云下载文件", "*.fs"), ("所有文件", "*.*")])
        if filename:
            self.fields["bitstream"].set(filename)
            self.save_settings()

    def browse_output(self):
        folder = filedialog.askdirectory(title="选择数据保存目录",
                                         initialdir=self.fields["output"].get())
        if folder:
            self.fields["output"].set(folder)
            self.save_settings()

    def choose_capture(self, title, key):
        folder = filedialog.askdirectory(title=title, initialdir=self.saved.get(
            key, self.fields["output"].get()))
        if folder:
            if not (Path(folder) / "capture.json").is_file():
                messagebox.showerror("数据目录无效", "请选择包含 capture.json 和 raw.bin 的采集目录。")
                return None
            self.saved[key] = folder
            self.save_settings()
        return folder

    def append(self, text):
        if text.startswith("Report: "):
            self.latest_report = Path(text[len("Report: "):].strip())
            text = f"报告已生成：{self.latest_report}\n"
        elif text.startswith("Saving capture: "):
            text = text.replace("Saving capture: ", "正在保存采集数据：", 1)
        self.log.configure(state="normal")
        self.log.insert("end", text)
        self.log.see("end")
        self.log.configure(state="disabled")

    def execute(self, command, operation):
        if self.busy:
            return
        self.save_settings()
        self.busy = True
        self.operation = operation
        self.output_lines = []
        self.latest_report = None
        self.verdict.set("正在检测")
        self.verdict_label.configure(foreground="#242a30")
        for value in self.metrics:
            value.set("—")
        self.detail.set("")
        self.status.set(operation)
        self.append(f"\n{operation}\n")
        self.progress.start(12)
        for widget, _ in self.controls:
            widget.configure(state="disabled")

        def worker():
            try:
                with subprocess.Popen(
                    command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, encoding="utf-8", errors="replace",
                    env={**os.environ, "PYTHONIOENCODING": "utf-8"},
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                ) as process:
                    for line in process.stdout:
                        self.events.put(("line", line))
                    self.events.put(("done", process.wait()))
            except Exception as error:
                self.events.put(("line", f"运行出错：{error}\n"))
                self.events.put(("done", -1))
        threading.Thread(target=worker, daemon=True).start()

    def poll(self):
        while True:
            try:
                kind, value = self.events.get_nowait()
            except queue.Empty:
                break
            if kind == "line":
                self.output_lines.append(value)
                self.append(value)
            else:
                self.finished(value)
        self.poll_id = self.window.after(80, self.poll)

    def finished(self, code):
        self.busy = False
        self.progress.stop()
        for widget, state in self.controls:
            widget.configure(state=state)
        result = last_result("".join(self.output_lines))
        verdict = result.get("comparison", result.get("spectral_check"))
        valid = code in (0, 2) and verdict in ("PASS", "FAIL")
        passed = valid and code == 0 and verdict == "PASS"
        self.verdict.set("检测通过" if passed else "检测未通过" if valid else "运行失败")
        self.verdict_label.configure(foreground="#17675c" if passed else "#ac303d")
        self.status.set("检测完成" if valid else "运行失败，请查看运行日志")
        if "spectral_check" in result:
            for var, title in zip(self.metric_titles,
                                  ("检出的目标谱峰", "期望谱峰", "异常目标谱峰")):
                var.set(title)
            for var, key in zip(self.metrics, ("matched_enabled_peaks", "expected_peaks",
                                              "unexpected_enabled_targets")):
                var.set(str(result.get(key, "—")))
            self.detail.set(
                f"采样率：{result.get('sample_rate_hz', 0):,.0f} Hz    "
                f"记录时长：{result.get('record_seconds', 0):.3f} 秒\n"
                f"削顶：{'是' if result.get('clipped') else '否'}    "
                f"时钟拟合触及边界：{'是' if result.get('clock_fit_at_boundary') else '否'}")
        elif "comparison" in result:
            for var, title in zip(self.metric_titles,
                                  ("对比通过路数", "对比总路数", "异常路数")):
                var.set(title)
            rows = result.get("rows", [])
            self.metrics[0].set(str(sum(bool(r.get("match")) for r in rows)))
            self.metrics[1].set(str(len(rows)))
            self.metrics[2].set(str(sum(not r.get("match", False) for r in rows)))
            self.detail.set(
                f"以上数量为对比检查通过路数 / 总路数 / 异常路数。\n"
                f"公共增益变化：{result.get('common_gain_change_db', 0):+.3f} dB\n"
                "频率标注、静音抑制和逐路误差见对比报告。")
        else:
            self.detail.set("采集或分析没有完成。详细原因见“运行日志”。")
        self.append(f"\n{self.verdict.get()}（退出码 {code}）\n")

    def capture(self):
        if not self.fields["ip"].get().strip():
            messagebox.showerror("缺少示波器地址", "请填写示波器 IP。")
            return
        if not Path(self.fields["bitstream"].get()).is_file():
            messagebox.showerror("缺少下载文件", "请选择板上实际下载的 .fs 文件，用于记录校验值。")
            return
        if not self.fields["output"].get().strip():
            messagebox.showerror("缺少保存目录", "请选择数据保存目录。")
            return
        if not messagebox.askokcancel(
            "采集前确认",
            "请确认：\n\n"
            "• 板上 TEST 已稳定，且状态与所选测试状态一致。\n"
            "• DAC 已连接所选示波器通道。\n"
            "• 示波器已停止采集（STOP）。\n"
            "• 记录时长至少 0.342 秒，采样率至少 48 kSa/s。",
        ):
            return
        command = [sys.executable, "-u", str(ROOT / "tools/acceptance_scope.py"),
                   "capture", "--auto-folder"]
        for key, value in self.fields.items():
            command.extend((f"--{key}", value.get().strip()))
        self.execute(command, "正在采集并分析")

    def replay(self):
        folder = self.choose_capture("选择要分析的采集目录", "last_capture")
        if folder:
            self.execute([sys.executable, "-u", str(ROOT / "tools/acceptance_scope.py"),
                          "analyze", folder], "正在分析已有数据")

    def compare(self):
        baseline = self.choose_capture("选择全部开启（ALL）的采集目录", "last_all")
        if not baseline:
            return
        changed = self.choose_capture("选择单路静音（MUTE）的采集目录", "last_mute")
        if changed:
            self.execute([sys.executable, "-u", str(ROOT / "tools/acceptance_scope.py"),
                          "compare", baseline, changed], "正在对比全开与单路静音")

    def open_report(self):
        filename = self.latest_report
        if filename is None or not filename.is_file():
            filename = filedialog.askopenfilename(
                title="打开检测报告", initialdir=self.fields["output"].get(),
                filetypes=[("离线检测报告", "*.html")])
        if filename:
            try:
                os.startfile(str(filename))
            except OSError as error:
                messagebox.showerror("报告打开失败", str(error))

    def close(self):
        if self.busy:
            messagebox.showwarning("任务正在运行", "请等待采集和分析完成后再关闭窗口。")
            return
        self.save_settings()
        self.window.after_cancel(self.poll_id)
        self.window.destroy()


def main():
    configure_dpi()
    window = tk.Tk()
    AcceptanceApp(window)
    window.mainloop()


if __name__ == "__main__":
    main()

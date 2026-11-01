"""Joint timing settings and offline review in the measurement suite."""

from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from acceptance_extra_pages import WorkerPage, ROOT
from measurement_files import directory, pick_record, report_folder, raw_record_for_report


class ScanValidationPage(WorkerPage):
    def __init__(self, root, owner):
        super().__init__(root, owner)
        self.page.configure(padding=0)
        self.latency = owner.latency
        header = ttk.Frame(self.page)
        header.pack(fill="x")
        ttk.Label(header, text="联合接线", style="Section.TLabel").pack(side="left", padx=(0, 12))
        self.confirm = tk.BooleanVar(value=False)
        self.confirm_check = ttk.Checkbutton(
            self.page, variable=self.confirm, text="已核对 D0=A 行、D1=B 行、D2=当前列，所有地接公共 GND")
        self.confirm_check.pack(anchor="w", pady=(4, 0))
        self.controls.append((self.confirm_check, "normal"))
        self.add_button(header, "检测逻辑分析仪", self.detect_logic)
        self.add_button(header, "接线说明", self.help)
        self.advanced_toggle = tk.BooleanVar(value=False)
        self.advanced_check = ttk.Checkbutton(
            self.page, text="误差预算与采样设置", variable=self.advanced_toggle, command=self.set_mode)
        self.advanced_check.pack(anchor="w", pady=4)
        self.controls.append((self.advanced_check, "normal"))
        self.offline_toggle = tk.BooleanVar(value=False)
        self.offline_check = ttk.Checkbutton(
            self.latency.offline_host, text="离线联合复核", variable=self.offline_toggle, command=self.set_mode)
        self.offline_check.pack(anchor="w")
        self.controls.append((self.offline_check, "normal"))
        self.offline = ttk.Frame(self.latency.offline_host)
        form = self.offline
        self.trial = tk.StringVar()
        self.csv = tk.StringVar()
        self.names = [tk.StringVar(value=n) for n in ("Time [s]", "Channel 0", "Channel 1", "Channel 2")]
        self.margin = tk.StringVar()
        self.ppm = tk.StringVar()
        self.rate = tk.StringVar(value="24")
        self.field(form, "延迟原始记录", self.trial, 0)
        choose_trial = ttk.Button(form, text="选择 trial.json…", command=self.choose_trial)
        choose_trial.grid(row=0, column=2, padx=(8, 0))
        self.controls.append((choose_trial, "normal"))
        self.field(form, "逻辑分析仪 CSV", self.csv, 1)
        button = ttk.Button(form, text="选择…", command=self.choose_csv)
        button.grid(row=1, column=2, padx=(8, 0))
        self.controls.append((button, "normal"))
        self.column_fields = ttk.Frame(form)
        self.column_fields.grid(row=2, column=0, columnspan=3, sticky="ew")
        self.column_toggle = tk.BooleanVar(value=False)
        column_check = ttk.Checkbutton(form, text="CSV 列名映射", variable=self.column_toggle,
                                       command=self.set_mode)
        column_check.grid(row=3, column=0, columnspan=3, sticky="w", pady=4)
        self.controls.append((column_check, "normal"))
        for row, (label, variable) in enumerate(zip(
                ("时间列名（秒）", "A 行列名（低有效）", "B 行列名（低有效）", "列母线列名（低有效）"),
                self.names)):
            self.field(self.column_fields, label, variable, row)
        self.advanced = ttk.Frame(self.page)
        self.field(self.advanced, "分析余量（µs；留空仅观察）", self.margin, 0)
        self.field(self.advanced, "时基误差（ppm；留空仅观察）", self.ppm, 1)
        ttk.Label(self.advanced, text="数字采样率（MHz）").grid(row=2, column=0, sticky="w")
        rates = ttk.Combobox(self.advanced, textvariable=self.rate, values=("12", "24"),
                             state="readonly", width=8)
        rates.grid(row=2, column=1, sticky="w", pady=6)
        self.controls.append((rates, "readonly"))
        self.same_press = tk.BooleanVar(value=False)
        check = ttk.Checkbutton(form, text="两份记录来自同一次单键按压，包含按下前静止段，且已核对联合接线",
                                variable=self.same_press)
        check.grid(row=4, column=0, columnspan=3, sticky="w", pady=4)
        self.controls.append((check, "normal"))
        bar = ttk.Frame(form)
        bar.grid(row=5, column=0, columnspan=3, sticky="ew", pady=4)
        self.offline_button = self.add_button(bar, "验证并生成报告", self.analyze, True)
        self.status = self.latency.status
        self.progress = self.latency.transfer_bar
        self.progress_text = self.latency.transfer_text
        self.log = self.latency.log
        self.poll_id = self.root.after(100, self.poll)
        self.set_mode()

    def set_mode(self):
        offline = self.offline_toggle.get()
        show_settings = offline or self.latency.capture_mode.get() == "自动联合测量"
        if show_settings:
            self.page.pack(fill="x")
        else:
            self.page.pack_forget()
        self.offline.pack_forget()
        self.advanced.pack_forget()
        if offline:
            self.offline.pack(fill="x", pady=8)
        if self.advanced_toggle.get():
            self.advanced.pack(fill="x", pady=4)
        if self.column_toggle.get():
            self.column_fields.grid()
        else:
            self.column_fields.grid_remove()

    def run(self, worker, report=True):
        super().run(worker, report)
        if self.busy:
            self.latency.start_button.configure(state="disabled")
            self.latency.end_button.configure(state="disabled")
            self.latency.save_button.configure(state="disabled")
            self.latency.joint_button.configure(state="disabled")
            for radio in self.latency.capture_modes:
                radio.configure(state="disabled")
            self.latency.result_tabs.select(1)

    def poll(self):
        was_busy = self.busy
        super().poll()
        if was_busy and not self.busy:
            self.latency.start_button.configure(state="disabled" if self.latency.config else "normal")
            self.latency.end_button.configure(state="normal" if self.latency.config else "disabled")
            self.latency.update_save()

    def choose_csv(self):
        selected = filedialog.askopenfilename(parent=self.root, title="选择数字采样 CSV",
                                              initialdir=str(directory("raw", "logic")),
                                              filetypes=(("CSV", "*.csv"),))
        if selected:
            self.csv.set(selected)

    def choose_trial(self):
        selected = pick_record(self.root, "latency", "选择同次按键的延迟记录 trial.json")
        if selected:
            self.trial.set(str(selected))

    def report_ready(self, path):
        super().report_ready(path)
        latency = self.owner.latency
        latency.latest_report = path
        latency.latest_folder = raw_record_for_report(path, "latency")
        spectrum = report_folder(latency.latest_folder, "latency") / "audio_spectrum.png"
        latency.latest_spectrum = spectrum if spectrum.is_file() else None
        latency.log_message("本次联合复核报告：" + str(path))
        if latency.config:
            latency.refresh()

    def help(self):
        import os
        os.startfile(ROOT / "docs/SCAN_LATENCY_VALIDATION.md")

    def detect_logic(self):
        from logic_automation import detect
        self.run(detect, report=False)

    def analyze(self):
        if self.owner.any_busy():
            messagebox.showwarning("任务正在运行", "请等待当前任务结束。", parent=self.root)
            return
        try:
            trial, source = Path(self.trial.get().strip()), Path(self.csv.get().strip())
            if not (trial / "trial.json").is_file() or not source.is_file():
                raise ValueError("请选择包含 trial.json 的单次记录目录和数字 CSV。")
            if not self.confirm.get() or not self.same_press.get():
                raise ValueError("请先核实并勾选同次记录、接线及起点口径。")
            margin, ppm = float(self.margin.get() or "0"), float(self.ppm.get() or "0")
            names = [v.get().strip() for v in self.names]
            rate = int(self.rate.get()) * 1_000_000
        except ValueError as error:
            messagebox.showerror("信息不完整", str(error), parent=self.root)
            return
        def worker():
            from scan_latency_validation import generate
            self.events.put(("log", "正在离线校验原始数据、扫描周期和共同列信号；不连接仪器。"))
            return generate(trial, source, names, margin, ppm, True, rate,
                            observation_only=not margin or not ppm)
        self.run(worker)

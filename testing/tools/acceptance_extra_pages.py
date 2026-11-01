"""LRCK and evidence-summary pages embedded in the existing desktop suite."""

import os
from pathlib import Path
import queue
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, scrolledtext, ttk

from scope_preflight import inspect_scope
from measurement_files import directory, pick_record, pick_firmware, open_artifact

ROOT = Path(__file__).resolve().parents[1]


def next_folder(base, prefix):
    base = Path(base)
    number = 1
    while (base / f"{prefix}_{number:03}").exists():
        number += 1
    return base / f"{prefix}_{number:03}"


class WorkerPage:
    def __init__(self, root, owner):
        self.root, self.owner = root, owner
        self.busy = False
        self.events = queue.Queue()
        self.latest_report = None
        self.controls = []
        self.status = tk.StringVar(value="未开始")
        self.page = ttk.Frame(root, padding=18)
        self.page.pack(fill="both", expand=True)

    def field(self, parent, label, variable, row, browse=False):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=(0, 12), pady=6)
        entry = ttk.Entry(parent, textvariable=variable)
        entry.grid(row=row, column=1, sticky="ew", pady=6)
        self.controls.append((entry, "normal"))
        parent.columnconfigure(1, weight=1)
        if browse:
            if browse in ("lrck", "polyphony"):
                command = lambda: self.browse_record(variable, browse)
            else:
                command = (lambda: self.browse_firmware(variable)) if browse == "firmware" else (
                    lambda: self.browse(variable))
            button = ttk.Button(parent, text="选择原始记录…" if browse in ("lrck", "polyphony") else "选择 .fs…",
                                command=command)
            button.grid(row=row, column=2, padx=(8, 0))
            self.controls.append((button, "normal"))

    def browse(self, variable):
        selected = filedialog.askdirectory(parent=self.root, initialdir=str(ROOT / "measurements"))
        if selected:
            variable.set(selected)

    def browse_firmware(self, variable):
        selected = pick_firmware(self.root, variable.get())
        if selected:
            variable.set(selected)

    def browse_record(self, variable, kind):
        selected = pick_record(self.root, kind, "选择 LRCK 记录 capture.json" if kind == "lrck"
                               else "选择复音 ALL 记录 capture.json", all_voices=kind == "polyphony")
        if selected:
            variable.set(str(selected))

    def fixed_output(self, parent, variable, kind, row, group="raw"):
        variable.set(str(directory(group, kind)))
        ttk.Label(parent, text="原始记录目录" if group == "raw" else "报告保存目录").grid(
            row=row, column=0, sticky="w", padx=(0, 12), pady=6)
        ttk.Entry(parent, textvariable=variable, state="readonly").grid(
            row=row, column=1, sticky="ew", pady=6)
        def open_directory():
            path = directory(group, kind)
            path.mkdir(parents=True, exist_ok=True)
            os.startfile(path)
        ttk.Button(parent, text="打开目录", command=open_directory).grid(row=row, column=2, padx=(8, 0))

    def action_grid(self, parent, commands, columns=2):
        self.action_buttons = []
        for column in range(columns):
            parent.columnconfigure(column, weight=1, uniform="action")
        for index, (text, command) in enumerate(commands):
            button = ttk.Button(parent, text=text, command=command,
                                style="Primary.TButton" if index == 0 else "TButton")
            button.grid(row=index // columns, column=index % columns, sticky="ew", padx=4, pady=4)
            self.controls.append((button, "normal"))
            self.action_buttons.append(button)

    def footer(self):
        ttk.Label(self.page, textvariable=self.status, wraplength=820).pack(anchor="w", pady=8)
        self.progress = ttk.Progressbar(self.page, maximum=100)
        self.progress.pack(fill="x", pady=4)
        self.progress_text = tk.StringVar(value="等待任务")
        ttk.Label(self.page, textvariable=self.progress_text, style="Muted.TLabel").pack(anchor="w")
        self.log = scrolledtext.ScrolledText(self.page, height=10, wrap="word", state="disabled")
        self.log.pack(fill="both", expand=True, pady=(8, 0))
        self.poll_id = self.root.after(100, self.poll)

    def append(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", text.rstrip() + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def run(self, worker, report=True):
        if self.owner.any_busy():
            messagebox.showwarning("任务正在运行", "请等待当前采集或分析结束。", parent=self.root)
            return
        self.busy = True
        self.latest_report = None
        for widget, _ in self.controls:
            widget.configure(state="disabled")
        self.progress.configure(mode="indeterminate", value=0)
        self.progress.start(12)
        self.status.set("正在处理……")
        self.progress_text.set("准备中")
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")

        def execute():
            try:
                self.events.put(("done" if report else "checked", str(worker())))
            except Exception as error:
                self.events.put(("error", str(error)))
        threading.Thread(target=execute, daemon=True).start()

    def poll(self):
        try:
            while True:
                kind, value = self.events.get_nowait()
                if kind == "progress":
                    done, total = value
                    self.progress.stop()
                    self.progress.configure(mode="determinate", maximum=total, value=done)
                    self.progress_text.set(f"{done:,}/{total:,} 点 · {done / total:.1%}")
                    self.status.set("读取完成，正在分析原始波形……" if done == total else "正在读取原始采样点……")
                elif kind == "log":
                    self.append(value)
                elif kind == "confirm":
                    event, response, text = value
                    response.append(messagebox.askokcancel("设置建议：仍可继续",
                                                          text + "\n\n继续下载？", parent=self.root))
                    event.set()
                elif kind in ("done", "checked", "error"):
                    self.busy = False
                    self.progress.stop()
                    self.progress.configure(mode="determinate", maximum=100, value=0 if kind == "error" else 100)
                    self.progress_text.set("未完成" if kind == "error" else "已完成")
                    for widget, state in self.controls:
                        widget.configure(state=state)
                    self.append(value)
                    if kind == "done":
                        self.report_ready(Path(value))
                        self.status.set("报告已生成；测量结果和待核实项请查看报告。")
                    elif kind == "checked":
                        self.status.set("检测完成，未启动采集；结果见日志。")
                    else:
                        self.status.set("处理未完成，原因见日志。已下载的数据不会删除。")
                        messagebox.showerror("未完成", value, parent=self.root)
        except queue.Empty:
            pass
        self.poll_id = self.root.after(100, self.poll)

    def report_ready(self, path):
        self.latest_report = path

    def open_report(self):
        open_artifact(self.root, self.kind, "report", self.latest_report)

    def add_button(self, bar, text, command, primary=False):
        button = ttk.Button(bar, text=text, command=command,
                            style="Primary.TButton" if primary else "TButton")
        button.pack(side="left", padx=(0, 8), pady=4)
        self.controls.append((button, "normal"))
        return button


class LRCKPage(WorkerPage):
    def __init__(self, root, owner):
        super().__init__(root, owner)
        self.kind = "lrck"
        ttk.Label(self.page, text="LRCK 输出采样率", style="Title.TLabel").pack(anchor="w")
        ttk.Label(self.page, text="DAC 丝印 LCK（DIN 与 FMT 之间）→ 所选通道信号端；GND → 探头地。",
                  wraplength=820).pack(anchor="w", pady=(12, 4))
        ttk.Label(self.page, text="不是顶部模拟 L。两通道地内部相连，只接公共 GND；断电夹线，避免短接相邻焊点。",
                  wraplength=820, style="Muted.TLabel").pack(anchor="w")
        form = ttk.Frame(self.page)
        form.pack(fill="x", pady=8)
        self.ip = tk.StringVar(value=owner.polyphony.fields["ip"].get())
        self.firmware = tk.StringVar(value=owner.polyphony.fields["bitstream"].get())
        self.output = tk.StringVar()
        self.channel = tk.StringVar(value="1")
        self.field(form, "示波器 IP", self.ip, 0)
        self.field(form, "实际烧录文件 .fs（人工确认）", self.firmware, 1, browse="firmware")
        self.fixed_output(form, self.output, "lrck", 2)
        ttk.Label(form, text="采集通道").grid(row=3, column=0, sticky="w")
        combo = ttk.Combobox(form, textvariable=self.channel, values=("1", "2"), state="readonly", width=6)
        combo.grid(row=3, column=1, sticky="w", pady=6)
        self.controls.append((combo, "readonly"))
        self.confirmed = tk.BooleanVar(value=False)
        self.stopped = tk.BooleanVar(value=False)
        for label, variable in (
                ("已核对 LCK/GND 接线、真实探头倍率与示波器倍率一致", self.confirmed),
                ("本次已重新采集并停止（STOP）", self.stopped)):
            check = ttk.Checkbutton(self.page, text=label, variable=variable)
            check.pack(anchor="w", pady=3)
            self.controls.append((check, "normal"))
        bar = ttk.Frame(self.page)
        bar.pack(fill="x", pady=8)
        self.action_grid(bar, (
            ("下载 STOP 数据并分析", self.capture), ("选择记录重新分析…", self.analyze_saved),
            ("选择采样率报告…", self.open_report),
            ("选择示波器原屏…", lambda: open_artifact(self.root, "lrck", "screen"))))
        self.footer()

    def check(self, host, channel):
        result = inspect_scope(host, "lrck", channel)
        self.events.put(("log", result.text()))
        if result.errors:
            raise ValueError(result.text())
        if result.warnings:
            event, response = threading.Event(), []
            self.events.put(("confirm", (event, response, "\n".join(result.warnings))))
            event.wait()
            if not response[0]:
                raise ValueError("已取消，未下载")
        return result

    def capture(self):
        if not self.confirmed.get() or not self.stopped.get():
            messagebox.showwarning("请先确认", "请核对 LCK 接线、倍率，并确认本次已重新采集并停止。",
                                   parent=self.root)
            return
        host, firmware, channel = self.ip.get().strip(), self.firmware.get().strip(), int(self.channel.get())
        if not host or not firmware or not self.output.get().strip():
            messagebox.showerror("缺少信息", "请填写 IP、固件版本和保存目录。", parent=self.root)
            return
        if not Path(firmware).is_file() or Path(firmware).suffix.lower() != ".fs":
            messagebox.showerror("固件选择无效", "请选择实际烧录的 .fs 文件，不能只填版本名称。", parent=self.root)
            return
        output = next_folder(self.output.get(), "lrck")

        def worker():
            from lrck_measurement import capture
            self.check(host, channel)
            return capture(host, channel, output, firmware,
                           lambda done, total: self.events.put(("progress", (done, total))), True)
        if self.owner.any_busy():
            messagebox.showwarning("任务正在运行", "请等待当前任务结束。", parent=self.root)
            return
        self.stopped.set(False)
        self.run(worker)

    def analyze_saved(self):
        folder = pick_record(self.root, "lrck", "选择要分析的 LRCK 记录 capture.json")
        if folder:
            def worker():
                from lrck_measurement import generate
                return generate(folder)
            self.run(worker)

    def detect(self):
        host, channel = self.ip.get().strip(), int(self.channel.get())
        if not host:
            messagebox.showerror("缺少地址", "请填写示波器 IP。", parent=self.root)
            return
        # Detection alone must not create a measurement or report.
        if self.owner.any_busy():
            messagebox.showwarning("任务正在运行", "请等待当前任务结束。", parent=self.root)
            return
        self.busy = True
        self.status.set("正在检测示波器……")

        def worker():
            try:
                self.events.put(("detected", inspect_scope(host, "lrck", channel, require_stop=False)))
            except Exception as error:
                self.events.put(("error", str(error)))
        threading.Thread(target=worker, daemon=True).start()

    def poll(self):
        # Route read-only checks separately from report-producing operations.
        rest = []
        try:
            while True:
                item = self.events.get_nowait()
                if item[0] == "detected":
                    self.busy = False
                    self.append(item[1].text())
                    self.status.set("检查未通过" if item[1].errors else "检查通过；未采集数据")
                    (messagebox.showerror if item[1].errors else messagebox.showinfo)(
                        "示波器检查", item[1].text(), parent=self.root)
                else:
                    rest.append(item)
        except queue.Empty:
            pass
        for item in rest:
            self.events.put(item)
        super().poll()


class EvidencePage(WorkerPage):
    def __init__(self, root, owner):
        super().__init__(root, owner)
        self.kind = "evidence"
        ttk.Label(self.page, text="评分证据汇总", style="Title.TLabel").pack(anchor="w")
        form = ttk.Frame(self.page)
        form.pack(fill="x", pady=12)
        self.lrck = tk.StringVar()
        self.poly = tk.StringVar()
        self.output = tk.StringVar()
        self.count = tk.StringVar(value="64")
        self.count_verified = tk.BooleanVar(value=False)
        # A confirmation belongs to this count and these two selected records.
        for variable in (self.count, self.lrck, self.poly):
            variable.trace_add("write", lambda *_: self.count_verified.set(False))
        self.field(form, "LRCK 原始记录", self.lrck, 0, "lrck")
        self.field(form, "复音 ALL 原始记录", self.poly, 1, "polyphony")
        ttk.Label(form, text="独立振荡器数量").grid(row=2, column=0, sticky="w", pady=4)
        ttk.Spinbox(form, from_=1, to=4096, textvariable=self.count, width=10).grid(
            row=2, column=1, sticky="w", pady=4)
        ttk.Checkbutton(form, text="数量及独立性已人工核实，依据见技术文档",
                        variable=self.count_verified).grid(
            row=3, column=1, sticky="w", pady=4)
        self.fixed_output(form, self.output, "evidence", 4, "reports")
        table = ttk.Treeview(self.page, columns=("item", "state"), show="headings", height=6)
        table.heading("item", text="证据项目")
        table.heading("state", text="证据边界")
        table.column("item", width=240, stretch=False)
        table.column("state", width=540)
        for item, state in (
                ("实际输出采样率", "使用 LCK 原始数据计算，区别于示波器采样率"),
                ("配置声部数 / 匹配谱峰数", "从所选复音 ALL 记录读取，不作为独立振荡器数量"),
                ("独立振荡器数量", "由技术文档佐证，人工核实状态单独记录"),
                ("吞吐量计算", "所选数量 × 实测输出采样率；非正式比赛评分"),
                ("实时合成、无预录播放", "由 RTL、技术文档及构建证据佐证，不自动判定"),
                ("最终验收", "分别整理实测与人工核实记录，不宣布比赛通过")):
            table.insert("", "end", values=(item, state))
        table.pack(fill="x", pady=4)
        bar = ttk.Frame(self.page)
        bar.pack(fill="x", pady=8)
        self.action_grid(bar, (("核对记录并生成证据汇总", self.generate), ("选择证据汇总报告…", self.open_report)))
        self.footer()
        self.progress_text.set("离线整理，无需连接示波器")

    def generate(self):
        lrck, poly, output = (self.lrck.get().strip(), self.poly.get().strip(), self.output.get().strip())
        if not all((lrck, poly, output)):
            messagebox.showerror("缺少信息", "请选择 LRCK 和复音 ALL 原始记录。", parent=self.root)
            return
        try:
            count = int(self.count.get().strip())
            if not 1 <= count <= 4096:
                raise ValueError
        except ValueError:
            messagebox.showerror("数量无效", "独立振荡器数量请输入 1～4096 的整数。", parent=self.root)
            return

        count_verified = self.count_verified.get()

        def worker():
            from acceptance_evidence import generate
            return generate(lrck, poly, next_folder(output, "evidence"),
                            declared_count=count, count_user_verified=count_verified)
        self.run(worker)

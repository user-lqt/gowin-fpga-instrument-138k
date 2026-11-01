"""Unified acceptance desktop; upstream polyphony algorithms stay unchanged."""

import os
import queue
import re
from pathlib import Path
import sys
import threading
import tkinter as tk
from tkinter import font as tkfont
from tkinter import messagebox, ttk

import latency_gui
from acceptance_extra_pages import EvidencePage, LRCKPage
from scan_validation_page import ScanValidationPage
from scope_preflight import inspect_scope
from measurement_files import prepare

VENDOR = Path(__file__).resolve().parent / "polyphony_acceptance"
sys.path.insert(0, str(VENDOR))
import acceptance_gui as polyphony

ROOT = Path(__file__).resolve().parents[1]
polyphony.ROOT = ROOT


class PageHost(tk.Frame):
    """Embed an existing single-window UI without changing its algorithms."""

    def title(self, *_args):
        pass

    def geometry(self, *_args):
        pass

    def minsize(self, *_args):
        pass

    def protocol(self, *_args):
        pass


class ScrollPage(ttk.Frame):
    """Keep forms reachable on smaller screens and at larger font sizes."""

    def __init__(self, parent):
        super().__init__(parent)
        self.columnconfigure(0, weight=1)
        self.rowconfigure(0, weight=1)
        self.canvas = tk.Canvas(self, background="#f5f6f7", highlightthickness=0)
        self.canvas.grid(row=0, column=0, sticky="nsew")
        self.vertical = ttk.Scrollbar(self, orient="vertical", command=self.canvas.yview)
        self.vertical.grid(row=0, column=1, sticky="ns")
        self.horizontal = ttk.Scrollbar(self, orient="horizontal", command=self.canvas.xview)
        self.canvas.configure(yscrollcommand=self.vertical.set, xscrollcommand=self.horizontal.set)
        self.body = PageHost(self.canvas, background="#f5f6f7")
        self.item = self.canvas.create_window(0, 0, window=self.body, anchor="nw")
        self.resize_pending = None
        self.layout = None
        self.body.bind("<Configure>", self.schedule_resize)
        self.canvas.bind("<Configure>", self.schedule_resize)

    def schedule_resize(self, _event=None):
        if self.resize_pending is None:
            # Configure events can generate more Configure events; an idle
            # callback chain otherwise starves initial layout and input.
            self.resize_pending = self.after(25, self.resize)

    def resize(self, _event=None):
        self.resize_pending = None
        width = max(self.canvas.winfo_width(), self.body.winfo_reqwidth())
        height = max(self.canvas.winfo_height(), self.body.winfo_reqheight())
        horizontal = self.body.winfo_reqwidth() > self.canvas.winfo_width() + 2
        layout = (width, height, horizontal)
        if layout == self.layout:
            return
        self.layout = layout
        self.canvas.itemconfigure(self.item, width=width, height=height)
        self.canvas.configure(scrollregion=(0, 0, width, height))
        if horizontal:
            self.horizontal.grid(row=1, column=0, sticky="ew")
        else:
            self.horizontal.grid_remove()
            self.canvas.xview_moveto(0)


class PolyphonyPage(polyphony.AcceptanceApp):
    def __init__(self, window, owner, **kwargs):
        self.owner = owner
        if kwargs.get("settings_path") is None:
            kwargs["settings_path"] = ROOT / "config/settings.json"
        super().__init__(window, **kwargs)
        self.download_text = tk.StringVar(value="尚未读取")
        ttk.Label(self.progress.master, textvariable=self.download_text,
                  style="Muted.TLabel").pack(side="right", padx=12)

    def execute(self, command, operation, checked=False):
        self._execute(command, operation, checked)

    def append(self, text):
        match = re.fullmatch(r"(\d+)/(\d+) points\s*", text)
        if match:
            done, total = map(int, match.groups())
            self.progress.stop()
            self.progress.configure(mode="determinate", maximum=total, value=done)
            self.download_text.set(f"{done:,}/{total:,} 点 · {done / total:.1%}")
            self.status.set("读取完成，正在校验与频谱分析……" if done == total
                            else "正在读取示波器原始数据")
            return
        if text.startswith("Saving capture: "):
            self.download_text.set("已连接，准备下载原屏与原始数据……")
        super().append(text)

    def finished(self, code):
        super().finished(code)
        if code in (0, 2) and polyphony.last_result("".join(self.output_lines)):
            self.progress.configure(mode="determinate", maximum=100, value=100)
            self.download_text.set("100% · 读取与分析完成")
        elif code not in (0, 2):
            self.download_text.set("未完成，详见日志")
        result = polyphony.last_result("".join(self.output_lines))
        reasons = []
        if result.get("spectral_check") == "FAIL":
            if result.get("clipped"):
                reasons.append("原始采样存在接近量程上下限的样本（BYTE ≤1 或 ≥254），"
                               "判为削顶/过载风险。检查量程、偏移及记录中的启动瞬态。")
            if result.get("clock_fit_at_boundary"):
                reasons.append("时钟频率拟合触及搜索边界。")
            matched = result.get("matched_enabled_peaks")
            expected = result.get("expected_peaks")
            if matched is not None and expected is not None and matched != expected:
                reasons.append(f"目标谱峰不足：检出 {matched}，期望 {expected}。")
            if result.get("unexpected_enabled_targets", 0):
                reasons.append(f"存在 {result['unexpected_enabled_targets']} 个不应出现的目标谱峰。")
            spur = result.get("largest_non_target_db")
            if spur is not None and spur >= -12:
                reasons.append(f"最大非目标谱峰 {spur:+.2f} dB，要求 < −12 dB"
                               "（相对开启声部谱峰中位数，不是 dBFS）。")
            if not reasons:
                reasons.append("目标匹配或参考幅度条件未满足，需检查完整分析报告。")
        elif result.get("comparison") == "FAIL":
            gain = result.get("common_gain_change_db", 0)
            if abs(gain) > 3:
                reasons.append(f"公共增益变化 {gain:+.2f} dB，要求绝对值 ≤3 dB。")
            failed = [str(row["voice"]) for row in result.get("rows", []) if not row.get("match")]
            if failed:
                reasons.append("逐路对比未通过：" + "、".join(failed))
            reasons.append("对比还要求 ALL、MUTE 两份记录各自的频谱检查均通过，"
                           "具体频谱原因见各自报告。")
        if reasons:
            text = "\n\n未通过原因：\n" + "\n".join(
                f"{index}. {reason}" for index, reason in enumerate(reasons, 1))
            self.detail.set(self.detail.get() + text)
            self.append(text + "\n")

    def _execute(self, command, operation, checked=False):
        if self.busy:
            return
        if self.owner.any_busy(exclude=self):
            messagebox.showwarning("任务正在运行", "请等待其他测量或分析结束。", parent=self.owner.root)
            return
        if "capture" in command and not checked:
            self.log.configure(state="normal")
            self.log.delete("1.0", "end")
            self.log.configure(state="disabled")
            self.output_lines = []
            self.latest_report = None
            self.verdict.set("正在检查示波器")
            self.detail.set("")
            for metric in self.metrics:
                metric.set("—")
            self.owner.check_async("polyphony",
                                   lambda: self.execute(command, operation, checked=True))
            return
        command = list(command)
        command[0] = self.owner.python
        for index, argument in enumerate(command):
            if Path(argument).name == "acceptance_scope.py":
                command[index] = str(VENDOR / "acceptance_scope.py")
        self.progress.stop()
        self.progress.configure(mode="indeterminate", maximum=100, value=0)
        self.download_text.set("正在连接与准备……" if "capture" in command else "正在离线分析……")
        super().execute(command, operation)


class LatencyPage(latency_gui.LatencyApp):
    def __init__(self, window, owner):
        self.owner = owner
        super().__init__(window)

    def start(self, checked=False):
        if self.owner.any_busy(exclude=self):
            messagebox.showwarning("任务正在运行", "请等待其他测量或分析结束。", parent=self.owner.root)
            return
        super().start(checked=checked)

    def save(self):
        if self.owner.any_busy(exclude=self):
            messagebox.showwarning("任务正在运行", "请等待其他测量或分析结束。", parent=self.owner.root)
            return
        super().save()

    def end(self):
        if self.owner.any_busy(exclude=self):
            messagebox.showwarning("任务正在运行", "请等待当前测量或复核结束。", parent=self.root)
            return
        super().end()

    def joint_start(self, checked=False):
        if self.owner.any_busy():
            messagebox.showwarning("任务正在运行", "请等待当前任务结束。", parent=self.root)
            return
        if not self.config or not self.current:
            messagebox.showwarning("请先建立计划", "选择按键和次数、确认固件，再建立测量计划。", parent=self.root)
            return
        try:
            import math
            margin = float(self.owner.scan.margin.get() or "0")
            ppm = float(self.owner.scan.ppm.get() or "0")
            rate = int(self.owner.scan.rate.get()) * 1_000_000
            if not all(math.isfinite(v) and v >= 0 for v in (margin, ppm)):
                raise ValueError()
            if not self.owner.scan.confirm.get():
                raise ValueError()
        except ValueError:
            messagebox.showerror("先核实联合测量设置",
                                 "请在本页“联合接线”勾选确认；误差预算可留空，留空时只采集分析、不判定 5 ms 达标。",
                                 parent=self.root)
            return
        if not checked:
            if not messagebox.askokcancel(
                    "开始联合采集",
                    "此操作会启动 Logic 2 的 D0/D1/D2 采集，并向示波器发送 SINGLE。\n"
                    "CH1 接列母线，CH2 接模拟 L；D0 接 A 行、D1 接 B 行、D2 接同一列。\n"
                    "示波器先 STOP，设 CH1 下降沿触发；不要提前按键。\n\n"
                    "出现“现在只按一次目标键”提示后再按键，15 秒内未触发则停止本次采集。\n"
                    "确认接线正确并开始？", parent=self.root):
                return
            self.owner.check_async("latency", lambda: self.joint_start(checked=True))
            return
        self.busy = True
        self.update_save()
        self.start_button.configure(state="disabled")
        self.end_button.configure(state="disabled")
        self.transfer_bar.configure(mode="indeterminate", value=0)
        self.transfer_bar.start(12)
        self.transfer_text.set("正在准备两台仪器")
        self.status.set("正在准备联合采集，请勿提前按键。")
        config = dict(self.config, joint=True, logic_rate=rate,
                      analysis_margin_us=margin, clock_ppm=ppm)
        self.latest_report = self.latest_folder = self.latest_spectrum = None
        self.stopped.set(False)
        key, number = self.current
        threading.Thread(target=self.capture, args=(config, key, number), daemon=True).start()

    def analyze_saved(self):
        if self.owner.any_busy(exclude=self):
            messagebox.showwarning("任务正在运行", "请等待其他测量或分析结束。", parent=self.owner.root)
            return
        super().analyze_saved()

    def apply_progress(self, summaries):
        super().apply_progress(summaries)
        for index, item in enumerate(self.tree.get_children()):
            self.tree.item(item, tags=("even" if index % 2 == 0 else "odd",))
        self.result_tabs.select(0)

    def log_message(self, text):
        super().log_message(text)
        if "result_tabs" in self.__dict__ and (
                "Traceback" in text or "Error" in text or "保存失败" in text):
            self.result_tabs.select(1)


class AcceptanceSuite:
    def __init__(self, root, settings_path=None):
        prepare()
        self.root = root
        self.check_events = queue.Queue()
        self.check_pending = None
        self.python = str(Path(sys.executable).with_name("python.exe")) if os.name == "nt" else sys.executable
        root.title("高云电子琴 · 测量与验收")
        width = min(1200, max(960, root.winfo_screenwidth() - 80))
        height = min(940, max(640, root.winfo_screenheight() - 100))
        root.geometry(f"{width}x{height}")
        root.minsize(920, 640)
        shell = ttk.Frame(root)
        shell.pack(fill="both", expand=True)
        toolbar = ttk.Frame(shell, padding=(24, 12, 24, 8))
        toolbar.pack(fill="x")
        ttk.Label(toolbar, text="高云电子琴", style="Brand.TLabel").pack(side="left")
        ttk.Label(toolbar, text="测量与验收", style="Muted.TLabel").pack(side="left", padx=16)
        self.font_size = tk.StringVar(value="标准")
        self.font_picker = ttk.Combobox(toolbar, textvariable=self.font_size, state="readonly",
                                       values=("小", "标准", "大"), width=6)
        self.font_picker.pack(side="right")
        ttk.Label(toolbar, text="字号", style="Muted.TLabel").pack(side="right", padx=(16, 8))
        self.font_picker.bind("<<ComboboxSelected>>", lambda _event: self.configure_style())
        self.detect_button = ttk.Button(toolbar, text="检查复音连接与设置", command=self.detect)
        self.detect_button.pack(side="right", padx=16)
        ttk.Button(toolbar, text="操作说明", command=lambda: os.startfile(
            ROOT / "docs/操作说明.md")).pack(side="right")
        self.tabs = ttk.Notebook(shell)
        self.tabs.pack(fill="both", expand=True, padx=16, pady=(0, 4))
        self.poly_scroll = ScrollPage(self.tabs)
        self.latency_scroll = ScrollPage(self.tabs)
        self.tabs.add(self.poly_scroll, text="复音验收")
        self.tabs.add(self.latency_scroll, text="按键延迟")
        self.polyphony = PolyphonyPage(self.poly_scroll.body, self, settings_path=settings_path)
        self.latency = LatencyPage(self.latency_scroll.body, self)
        self.lrck_scroll = ScrollPage(self.tabs)
        self.evidence_scroll = ScrollPage(self.tabs)
        self.tabs.add(self.lrck_scroll, text="LRCK 采样率")
        self.tabs.add(self.evidence_scroll, text="评分证据")
        self.lrck = LRCKPage(self.lrck_scroll.body, self)
        self.evidence = EvidencePage(self.evidence_scroll.body, self)
        self.scan = ScanValidationPage(self.latency.joint_settings, self)
        self.pages = (self.polyphony, self.latency, self.lrck, self.evidence, self.scan)
        self.scrolls = (self.poly_scroll, self.latency_scroll, self.lrck_scroll, self.evidence_scroll)
        saved_font = self.polyphony.saved.get("ui_font_size")
        if saved_font in ("小", "标准", "大"):
            self.font_size.set(saved_font)
        self.mode_status = tk.StringVar(value="复音验收 · DAC 模拟输出频谱")
        ttk.Label(shell, textvariable=self.mode_status, style="Muted.TLabel",
                  padding=(16, 6)).pack(fill="x")
        self.configure_style()
        self.poly_scroll.body.bind("<Configure>", self.wrap_polyphony, add="+")
        self.tabs.select(0)
        root.update_idletasks()
        self.last_tab = self.tabs.select()
        self.switching = False
        self.tabs.bind("<<NotebookTabChanged>>", self.tab_changed)
        self.root.bind_all("<MouseWheel>", self.mousewheel, add="+")
        root.protocol("WM_DELETE_WINDOW", self.close)
        self.check_poll_id = root.after(100, self.poll_checks)

    def any_busy(self, exclude=None):
        return self.check_pending is not None or any(
            page.busy for page in getattr(self, "pages", (self.polyphony, self.latency))
            if page is not exclude)

    def detect(self):
        index = self.tabs.index(self.tabs.select())
        if index == 2:
            self.lrck.detect()
        elif index == 3:
            messagebox.showinfo("离线证据整理", "此页不连接示波器；请在对应测量页检测。",
                                parent=self.root)
        else:
            self.check_async("latency" if index == 1 else "polyphony", require_stop=False)

    def check_async(self, mode, callback=None, require_stop=True):
        if self.any_busy():
            messagebox.showwarning("任务正在运行", "请等待当前任务结束。", parent=self.root)
            return
        page = self.latency if mode == "latency" else self.polyphony
        host = self.latency.ip.get() if mode == "latency" else self.polyphony.fields["ip"].get()
        if not host.strip():
            messagebox.showerror("缺少地址", "请填写当前示波器 IP。", parent=self.root)
            return
        channel = int(self.polyphony.fields["channel"].get()) if mode == "polyphony" else 1
        profile = self.latency.scope_profile() if mode == "latency" else mode
        self.check_pending = (mode, callback)
        page.busy = True
        page.status.set("正在检测连接与采集设置……")
        self.detect_button.configure(state="disabled")
        if mode == "latency":
            self.latency.update_save()
            self.latency.start_button.configure(state="disabled")
            self.latency.end_button.configure(state="disabled")
        else:
            for widget, _ in self.polyphony.controls:
                widget.configure(state="disabled")
            self.polyphony.progress.start(12)

        def worker():
            try:
                self.check_events.put((inspect_scope(host, profile, channel, require_stop=require_stop), None))
            except Exception as error:
                self.check_events.put((None, str(error)))
        threading.Thread(target=worker, daemon=True).start()

    def poll_checks(self):
        try:
            result, error = self.check_events.get_nowait()
        except queue.Empty:
            pass
        else:
            mode, callback = self.check_pending
            self.check_pending = None
            page = self.latency if mode == "latency" else self.polyphony
            page.busy = False
            self.detect_button.configure(state="normal")
            if mode == "latency":
                page.start_button.configure(state="disabled" if page.config else "normal")
                page.end_button.configure(state="normal" if page.config else "disabled")
                page.stopped.set(False)
                page.update_save()
            else:
                page.progress.stop()
                for widget, state in page.controls:
                    widget.configure(state=state)
            text = result.text() if result else "连接失败，请检查当前 IP、网线、网段和电源。\n" + error
            if mode == "latency":
                page.log_message(text)
            else:
                page.append(text + "\n")
            passed = result is not None and not result.errors
            if passed and callback and result.warnings:
                passed = messagebox.askokcancel(
                    "设置建议：仍可继续",
                    "\n".join(result.warnings) + "\n\n仍按当前设置继续当前操作？", parent=self.root)
                if not passed:
                    page.status.set("已取消采集")
                    self.check_poll_id = self.root.after(100, self.poll_checks)
                    return
            page.status.set("连接及设置检查通过" if passed else "连接或设置检查未通过")
            if passed and callback:
                callback()
            elif passed:
                messagebox.showinfo("示波器检查通过", text, parent=self.root)
            else:
                messagebox.showerror("示波器检查未通过", text, parent=self.root)
                if mode == "polyphony" and callback:
                    page.verdict.set("未开始采集")
                    page.verdict_label.configure(foreground="#ac303d")
                    page.detail.set("连接或设置未通过检查，请查看运行日志。")
        self.check_poll_id = self.root.after(100, self.poll_checks)

    def configure_style(self):
        size = {"小": 11, "标准": 12, "大": 14}[self.font_size.get()]
        self.polyphony.saved["ui_font_size"] = self.font_size.get()
        font = ("Microsoft YaHei UI", size)
        for name in ("TkDefaultFont", "TkTextFont", "TkMenuFont"):
            tkfont.nametofont(name, root=self.root).configure(family=font[0], size=size)
        self.root.option_add("*TCombobox*Listbox.font", font)
        style = ttk.Style(self.root)
        style.configure(".", font=font, background="#f5f6f7", foreground="#242a30")
        style.configure("TFrame", background="#f5f6f7")
        style.configure("TLabel", background="#f5f6f7", foreground="#242a30")
        style.configure("Brand.TLabel", font=(font[0], size + 2, "bold"))
        style.configure("Title.TLabel", font=(font[0], size + 5, "bold"))
        style.configure("Section.TLabel", font=(font[0], size, "bold"))
        style.configure("Muted.TLabel", foreground="#626c76")
        style.configure("Metric.TLabel", font=(font[0], size + 8, "bold"))
        style.configure("TEntry", padding=(8, 6), fieldbackground="white")
        style.configure("TCombobox", padding=(8, 5), arrowsize=18)
        style.configure("TSpinbox", padding=(8, 6), arrowsize=16)
        style.configure("TCheckbutton", padding=(5, 4), background="#f5f6f7")
        style.map("TCheckbutton", background=[("active", "#e8efed"), ("disabled", "#f5f6f7")])
        style.configure("TButton", padding=(14, 8), borderwidth=1)
        for name in ("Primary.TButton", "Accent.TButton"):
            style.configure(name, background="#17675c", foreground="white")
            style.map(name, background=[("disabled", "#899d98"), ("active", "#105347")])
        style.configure("TNotebook", background="#f5f6f7", borderwidth=0)
        style.configure("TNotebook.Tab", padding=(18, 9), font=(font[0], size, "bold"))
        style.map("TNotebook.Tab", background=[("selected", "#e4efeb"), ("!selected", "#edf0f2")],
                  foreground=[("selected", "#105347"), ("!selected", "#4b565f")])
        style.configure("Treeview", font=font, rowheight=round(size * 2.8),
                        background="white", fieldbackground="white", borderwidth=0)
        style.configure("Treeview.Heading", font=(font[0], size, "bold"), padding=(10, 8),
                        background="#edf0f2")
        style.map("Treeview", background=[("selected", "#dcefe8")],
                  foreground=[("selected", "#104c40")])
        style.configure("TLabelframe", background="#f5f6f7")
        style.configure("TLabelframe.Label", background="#f5f6f7",
                        foreground="#4b565f", font=(font[0], size, "bold"))
        self.latency.start_button.configure(style="Primary.TButton")
        for log in (self.latency.log, self.polyphony.log, self.lrck.log, self.evidence.log):
            log.configure(background="white", foreground="#303840", font=font,
                          relief="flat", padx=12, pady=10, spacing1=3, spacing3=3)
        self.latency.tree.tag_configure("even", background="white")
        self.latency.tree.tag_configure("odd", background="#f2f6f5")
        self.polyphony.verdict_label.configure(wraplength=840)
        self.root.configure(background="#f5f6f7")

    def wrap_polyphony(self, _event=None):
        for child in (self.polyphony.detail_label, self.polyphony.verdict_label):
            length = max(240, child.master.winfo_width() - 32)
            if int(child.cget("wraplength") or 0) != length:
                child.configure(wraplength=length, justify="left")

    def mousewheel(self, event):
        widget = self.root.winfo_containing(event.x_root, event.y_root)
        # Logs, results and selectors retain their own wheel behavior.
        current = widget
        while current is not None:
            if isinstance(current, (tk.Text, ttk.Treeview, ttk.Combobox, ttk.Spinbox)):
                return
            current = current.master
        page = self.scrolls[self.tabs.index(self.tabs.select())]
        if page.body.winfo_reqheight() > page.canvas.winfo_height():
            page.canvas.yview_scroll(-1 if event.delta > 0 else 1, "units")

    def tab_changed(self, _event=None):
        if self.switching:
            return
        selected = self.tabs.select()
        if selected == self.last_tab:
            return
        if self.any_busy():
            self.switching = True
            self.tabs.select(self.last_tab)
            self.switching = False
            messagebox.showwarning("任务正在运行", "请等待当前采集或分析完成后切换。", parent=self.root)
            return
        if not messagebox.askokcancel(
            "切换测量项目",
            "仅切换页面无需 STOP。若要更换物理接线，请先停止采集、断电夹线，"
            "并核对板上程序、时基与量程。\n\n"
            "复音：所选通道接 DAC 模拟输出，记录至少 0.342 秒。\n"
            "延迟：CH1 接待测键列，CH2 接 DAC 模拟 L；自动联合模式由软件启动 SINGLE，提示后再按键。\n"
            "LRCK：所选通道接 DAC 数字 LCK（DIN 与 FMT 之间），不是模拟 L；建议保留至少 1 ms。\n"
            "评分证据：离线整理，不启动采集。\n"
            "地夹只接已确认的公共 GND。切换页面不会自动启动采集或更改仪器设置。",
            parent=self.root):
            self.tabs.select(self.last_tab)
            return
        self.last_tab = selected
        index = self.tabs.index(selected)
        self.detect_button.configure(
            state="disabled" if index == 3 else "normal",
            text=("检查复音连接与设置", "检查延迟连接与设置",
                  "检查 LRCK 连接与设置", "离线页面无需连接")[index])
        self.latency.stopped.set(False)
        self.latency.update_save()
        self.lrck.stopped.set(False)
        self.lrck.confirmed.set(False)
        self.mode_status.set((
            "复音验收 · DAC 模拟输出频谱",
            "按键延迟 · 单页联合采集与离线复核",
            "LRCK 采样率 · DAC 数字 LCK 输入，非模拟 L",
            "评分证据 · 人工数量声明 × 实测 LRCK，非最终验收结论")[index])

    def close(self):
        if self.any_busy():
            messagebox.showwarning("任务正在运行", "请等待采集和分析完成后关闭。", parent=self.root)
            return
        self.polyphony.save_settings()
        self.dispose()

    def dispose(self):
        self.latency.hide_press_prompt()
        self.root.withdraw()
        self.root.after_cancel(self.check_poll_id)
        self.polyphony.window.after_cancel(self.polyphony.poll_id)
        self.latency.root.after_cancel(self.latency.poll_id)
        self.lrck.root.after_cancel(self.lrck.poll_id)
        self.evidence.root.after_cancel(self.evidence.poll_id)
        self.scan.root.after_cancel(self.scan.poll_id)
        for page in self.scrolls:
            if page.resize_pending is not None:
                page.after_cancel(page.resize_pending)
        self.root.destroy()


def main():
    root = latency_gui.create_root()
    root.withdraw()
    AcceptanceSuite(root)
    root.deiconify()
    root.mainloop()


if __name__ == "__main__":
    main()

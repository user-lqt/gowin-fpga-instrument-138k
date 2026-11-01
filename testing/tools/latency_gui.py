"""Desktop front end for the existing STOP-only scope capture script."""

import os
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, scrolledtext, ttk

import latency_session as session
from scope_preflight import inspect_scope
from measurement_files import directory, pick_record, pick_firmware, open_artifact, screen_file

TIMBRES = {"钢琴": "piano", "吉他": "guitar", "编钟": "bianzhong"}


def instrument_id(value):
    return session.instrument_id(TIMBRES.get(value, value))


def plan_progress_text(keys, initial_counts, targets):
    lines = []
    remaining = 0
    missing_keys = 0
    for key in keys:
        done, target = initial_counts[key], targets[key]
        missing = max(0, target-done)
        remaining += missing
        missing_keys += bool(missing)
        state = f"还需 {missing} 次" if missing else "无需补测"
        lines.append(f"K{key}：已可用 {done} 次 / 目标 {target} 次 / {state}")
    return (
        f"当前进度：还需 {missing_keys} 个键、共 {remaining} 条分析可用记录。\n"
        "以下是实际进度，目标次数不代表已完成：\n"
        + "\n".join(lines))


def saved_analysis_failure(trial):
    try:
        data = json.loads((Path(trial) / "latency_analysis_error.json").read_text(encoding="utf-8"))
        return str(data.get("message") or data.get("error") or "分析未生成有效报告。")
    except (OSError, ValueError, AttributeError):
        return "未找到具体分析错误，请查看运行日志。"


class PressPrompt:
    """Nonmodal notification: it never blocks acquisition or needs a click."""

    def __init__(self, parent, key):
        self.window = tk.Toplevel(parent.winfo_toplevel())
        self.window.withdraw()
        self.window.title("现在按键")
        self.window.transient(parent.winfo_toplevel())
        self.window.attributes("-topmost", True)
        self.window.configure(background="#105b4b", padx=32, pady=24)
        self.window.resizable(False, False)
        self.window.protocol("WM_DELETE_WINDOW", lambda: None)
        tk.Label(self.window, text="采集已就绪", background="#105b4b", foreground="#d8f2e8",
                 font=("Microsoft YaHei UI", 16)).pack()
        tk.Label(self.window, text=f"现在按一次 K{key}", background="#105b4b", foreground="white",
                 font=("Microsoft YaHei UI", 30, "bold")).pack(pady=(10, 14))
        tk.Label(self.window, text="按住直到提示消失，不要连续按键", background="#105b4b",
                 foreground="white", font=("Microsoft YaHei UI", 15)).pack()
        self.remaining = tk.StringVar()
        tk.Label(self.window, textvariable=self.remaining, background="#105b4b", foreground="#ffe092",
                 font=("Microsoft YaHei UI", 16, "bold")).pack(pady=(16, 0))
        self.deadline = time.monotonic() + 15
        self.timer = None
        self.window.update_idletasks()
        main = parent.winfo_toplevel()
        width, height = self.window.winfo_reqwidth(), self.window.winfo_reqheight()
        x = max(0, main.winfo_rootx() + (main.winfo_width() - width) // 2)
        y = max(0, main.winfo_rooty() + (main.winfo_height() - height) // 2)
        self.window.geometry(f"+{x}+{y}")
        self.window.deiconify()
        self.window.lift()
        self.window.bell()
        self.tick()

    def tick(self):
        seconds = max(0, int(self.deadline - time.monotonic() + .999))
        self.remaining.set(f"剩余等待约 {seconds} 秒" if seconds else "正在确认采集状态，请勿重复按键")
        self.timer = self.window.after(200, self.tick)

    def close(self):
        if self.timer is not None:
            self.window.after_cancel(self.timer)
            self.timer = None
        self.window.destroy()


class LatencyApp:
    def __init__(self, root):
        self.root = root
        root.title("电子琴延迟测量")
        root.geometry("1000x800")
        root.minsize(860, 700)
        self.events = queue.Queue()
        self.busy = False
        self.config = None
        self.current = None
        self.image = session.BASE
        self.latest_spectrum = None
        self.latest_report = None
        self.latest_folder = None
        self.press_prompt = None
        self.last_wiring_key = None
        try:
            saved_version = json.loads(session.VERSION.read_text(encoding="utf-8"))
            default_bitstream = saved_version["bitstream_path"]
            if not Path(default_bitstream).is_file() or not Path(default_bitstream).resolve().is_relative_to(session.ROOT):
                default_bitstream = ""
        except (OSError, ValueError, KeyError):
            default_bitstream = ""
        self.bitstream = tk.StringVar(value=default_bitstream)
        self.ip = tk.StringVar(value="169.254.229.90")
        self.count = tk.StringVar(value="3")
        self.mode = tk.StringVar(value="累计补齐")
        self.force = tk.StringVar(value="medium")
        self.instrument = tk.StringVar(value="钢琴")
        self.refresh_generation = 0
        self.volume = tk.StringVar(value="127")
        self.effects = tk.BooleanVar(value=False)
        self.stopped = tk.BooleanVar(value=False)
        self.status = tk.StringVar(value="未开始")
        self.key_label = tk.StringVar(value="请选择按键与测量次数")
        self.connection = tk.StringVar(value="CH1：待选择　　CH2：DAC 模拟 L")
        self.key_vars = [tk.BooleanVar(value=True) for _ in range(24)]
        style = ttk.Style(root)
        style.theme_use("clam")
        style.configure(".", font=("Microsoft YaHei UI", 10),
                        background="#f6f7f9", foreground="#202429")
        style.configure("Treeview", background="white", fieldbackground="white", rowheight=26)
        style.configure("Title.TLabel", font=("Microsoft YaHei UI", 16, "bold"))
        style.configure("Accent.TButton", foreground="white", background="#18766a", padding=8)

        page = ttk.Frame(root, padding=18)
        self.page = page
        page.pack(fill="both", expand=True)
        ttk.Label(page, text="电子琴延迟测量", style="Title.TLabel").pack(anchor="w")
        capture = ttk.Frame(page)
        self.capture_mode = tk.StringVar(value="手动示波器测量")
        if hasattr(self, "owner"):
            modes = ttk.Frame(page)
            modes.pack(fill="x", pady=(8, 0))
            self.capture_modes = []
            for label in ("自动联合测量", "手动示波器测量"):
                radio = ttk.Radiobutton(modes, text=label, value=label,
                                        variable=self.capture_mode, command=self.switch_capture_mode)
                radio.pack(side="left", padx=(0, 20))
                self.capture_modes.append(radio)
        self.settings = ttk.Frame(page)
        self.settings.pack(fill="x", pady=(12, 8))
        for column, (label, variable, width) in enumerate((
            ("示波器 IP", self.ip, 21), ("每键分析可用目标", self.count, 9),
            ("音色", self.instrument, 15), ("音量", self.volume, 8),
        )):
            cell = ttk.Frame(self.settings)
            self.settings.columnconfigure(column, weight=1)
            cell.grid(row=0, column=column, padx=(0, 16), sticky="ew")
            ttk.Label(cell, text=label).pack(anchor="w")
            if variable is self.instrument:
                entry = ttk.Combobox(cell, textvariable=variable, width=width,
                                     values=tuple(TIMBRES), state="readonly")
                self.instrument_picker = entry
            elif variable in (self.count, self.volume):
                entry = ttk.Spinbox(cell, textvariable=variable, width=width, from_=1 if variable is self.count else 0,
                                    to=2147483647 if variable is self.count else 127)
            else:
                entry = ttk.Entry(cell, textvariable=variable, width=width)
            entry.pack(fill="x", pady=4)
        options = ttk.Frame(self.settings)
        options.grid(row=1, column=0, columnspan=4, sticky="w", pady=4)
        ttk.Label(options, text="次数模式").pack(side="left")
        ttk.Combobox(options, textvariable=self.mode, values=("累计补齐", "本轮新增"),
                     state="readonly", width=12).pack(side="left", padx=(8, 24))
        ttk.Label(options, text="力度").pack(side="left")
        ttk.Combobox(options, textvariable=self.force, values=("soft", "medium", "hard"),
                     state="readonly", width=10).pack(side="left", padx=8)
        ttk.Checkbutton(options, text="音效开启", variable=self.effects).pack(side="left", padx=16)
        firmware = ttk.Frame(self.settings)
        firmware.grid(row=2, column=0, columnspan=4, sticky="ew", pady=6)
        ttk.Label(firmware, text="实际烧录文件（人工确认）").pack(anchor="w")
        line = ttk.Frame(firmware)
        line.pack(fill="x", pady=4)
        ttk.Entry(line, textvariable=self.bitstream).pack(side="left", fill="x", expand=True)
        ttk.Button(line, text="选择文件…", command=self.choose_bitstream).pack(side="right", padx=(8, 0))

        self.selection = ttk.Frame(page)
        self.selection.pack(fill="x")
        shortcuts = ttk.Frame(self.selection)
        shortcuts.pack(fill="x", pady=(4, 6))
        ttk.Label(shortcuts, text="测量按键").pack(side="left", padx=(0, 20))
        for label, keys in (("全选", range(24)), ("清空", ())):
            ttk.Button(shortcuts, text=label, command=lambda keys=keys: self.select(keys)).pack(side="left", padx=3)
        grid = ttk.Frame(self.selection)
        grid.pack(fill="x")
        for column in range(6):
            grid.columnconfigure(column, weight=1, uniform="key")
        for index, variable in enumerate(self.key_vars):
            ttk.Checkbutton(grid, text=f"K{index + 1}", variable=variable).grid(
                row=index // 6, column=index % 6, sticky="ew", padx=(4, 12), pady=3)

        bar = ttk.Frame(page)
        bar.pack(fill="x", pady=(12, 8))
        for column in range(3):
            bar.columnconfigure(column, weight=1, uniform="latency_action")
        self.start_button = ttk.Button(bar, text="建立测量计划", command=self.start)
        self.start_button.grid(row=0, column=0, sticky="ew", padx=(0, 8), pady=(0, 8))
        self.end_button = ttk.Button(bar, text="结束本轮", command=self.end, state="disabled")
        self.end_button.grid(row=0, column=1, sticky="ew", padx=(0, 8), pady=(0, 8))
        self.file_bar = ttk.Frame(page)
        for column in range(3):
            self.file_bar.columnconfigure(column, weight=1, uniform="latency_file")
        self.analyze_button = ttk.Button(self.file_bar, text="分析已有记录…", command=self.analyze_saved)
        for column, (text, command) in enumerate((
                ("选择延迟报告…", self.open_report),
                ("选择示波器原屏…", self.open_screen),
                ("选择音频频谱…", self.open_spectrum))):
            ttk.Button(self.file_bar, text=text, command=command).grid(
                row=0, column=column, sticky="ew",
                padx=(0, 8 if column < 2 else 0), pady=(0, 8))
        self.analyze_button.grid(row=1, column=0, sticky="ew", padx=(0, 8))
        ttk.Button(self.file_bar, text="当前原始目录", command=self.open_trial).grid(
            row=1, column=1, sticky="ew", padx=(0, 8))
        ttk.Button(self.file_bar, text="全部原始记录", command=self.open_folder).grid(
            row=1, column=2, sticky="ew")
        ttk.Separator(page).pack(fill="x")
        ttk.Label(page, textvariable=self.key_label, style="Title.TLabel").pack(anchor="w", pady=(12, 4))
        wiring_label = ttk.Label(page, textvariable=self.connection, justify="left", wraplength=820)
        wiring_label.pack(anchor="w", fill="x")
        wiring_label.bind("<Configure>", lambda event: wiring_label.configure(wraplength=max(300, event.width)))
        capture.pack(fill="x", pady=8)
        self.joint_settings = ttk.Frame(capture)
        self.joint_settings.pack(fill="x")
        self.manual_capture = ttk.Frame(capture)
        self.joint_capture = ttk.Frame(capture)
        self.check = ttk.Checkbutton(self.manual_capture, text="本次已重新采集并停止（STOP）",
                                    variable=self.stopped, command=self.update_save, state="disabled")
        self.check.pack(side="left")
        self.save_button = ttk.Button(self.manual_capture, text="保存本次", style="Accent.TButton",
                                      command=self.save, state="disabled")
        self.save_button.pack(side="right")
        if hasattr(self, "owner"):
            self.joint_button = ttk.Button(self.joint_capture, text="开始联合测量", command=self.joint_start)
            self.joint_button.pack(side="right", padx=8)
        self.switch_capture_mode()
        ttk.Label(page, textvariable=self.status).pack(anchor="w", pady=(0, 8))
        self.transfer_text = tk.StringVar(value="尚未读取")
        transfer = ttk.Frame(page)
        transfer.pack(fill="x", pady=(0, 8))
        self.transfer_bar = ttk.Progressbar(transfer, maximum=100, mode="determinate")
        self.transfer_bar.pack(side="left", fill="x", expand=True)
        ttk.Label(transfer, textvariable=self.transfer_text, width=34).pack(side="right", padx=(12, 0))
        self.result_tabs = ttk.Notebook(page)
        self.result_tabs.pack(fill="both", expand=True)
        progress_panel = ttk.Frame(self.result_tabs, padding=8)
        log_panel = ttk.Frame(self.result_tabs, padding=8)
        self.result_tabs.add(progress_panel, text="测量进度")
        self.result_tabs.add(log_panel, text="运行日志")
        self.tree = ttk.Treeview(progress_panel, columns=("key", "saved", "usable", "pending", "target", "status"),
                                 show="headings", height=4)
        for name, label in (("key", "按键"), ("saved", "已保存"), ("usable", "分析可用"),
                            ("pending", "待复核"), ("target", "可用目标"), ("status", "状态")):
            self.tree.heading(name, text=label)
            self.tree.column(name, width=105 if name != "status" else 160,
                             minwidth=70 if name != "status" else 120, anchor="center")
        scroll = ttk.Scrollbar(progress_panel, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=scroll.set)
        scroll.pack(side="right", fill="y")
        self.tree.pack(side="left", fill="both", expand=True)
        self.log = scrolledtext.ScrolledText(log_panel, height=4, state="disabled", font=("Consolas", 10),
                                            wrap="word")
        self.log.pack(fill="both", expand=True)
        ttk.Separator(page).pack(fill="x", pady=(12, 8))
        ttk.Label(page, text="记录与报告", style="Section.TLabel").pack(anchor="w", pady=(0, 6))
        self.file_bar.pack(fill="x")
        self.offline_host = ttk.Frame(page)
        self.offline_host.pack(fill="x", pady=(8, 0))
        root.protocol("WM_DELETE_WINDOW", self.close)
        self.poll_id = root.after(100, self.poll)

    def select(self, keys):
        for index, variable in enumerate(self.key_vars):
            variable.set(index in keys)

    def switch_capture_mode(self):
        self.stopped.set(False)
        self.manual_capture.pack_forget()
        self.joint_capture.pack_forget()
        panel = self.joint_capture if self.capture_mode.get() == "自动联合测量" else self.manual_capture
        panel.pack(fill="x")
        self.save_button.configure(state="disabled")
        if hasattr(self, "owner") and hasattr(self.owner, "scan"):
            self.owner.scan.set_mode()
        if self.current:
            self.show_wiring(self.current[0])

    def choose_bitstream(self):
        selected = pick_firmware(self.root, self.bitstream.get())
        if selected:
            self.bitstream.set(selected)

    def log_message(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", text.rstrip() + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def lock_settings(self, locked):
        def walk(parent):
            for widget in parent.winfo_children():
                if isinstance(widget, (ttk.Entry, ttk.Button, ttk.Checkbutton, ttk.Combobox)):
                    widget.configure(state="disabled" if locked else
                                     "readonly" if isinstance(widget, ttk.Combobox) else "normal")
                walk(widget)
        walk(self.settings)
        walk(self.selection)
        self.start_button.configure(state="disabled" if locked else "normal")
        self.end_button.configure(state="normal" if locked else "disabled")

    def clear_display(self):
        self.hide_press_prompt()
        self.tree.delete(*self.tree.get_children())
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")
        self.key_label.set("请选择按键与测量次数")
        self.connection.set("CH1：待选择　　CH2：DAC 模拟 L")
        self.stopped.set(False)
        self.latest_report = None
        self.latest_spectrum = None
        self.latest_folder = None
        self.last_wiring_key = None
        self.transfer_bar["value"] = 0
        self.transfer_text.set("尚未读取")
        self.result_tabs.select(0)

    def start(self, checked=False):
        if self.busy:
            return
        try:
            keys = [index + 1 for index, value in enumerate(self.key_vars) if value.get()]
            if not keys:
                raise ValueError("至少选择一个按键。")
            count = session.positive_integer(self.count.get())
            volume = int(self.volume.get())
            if not 0 <= volume <= 127:
                raise ValueError("音量须为 0～127。")
            if not self.ip.get().strip() or not self.instrument.get().strip():
                raise ValueError("示波器地址和音色不能为空。")
            if not Path(self.bitstream.get()).is_file():
                raise ValueError("请选择实际烧录的 .fs 文件；软件不能读取板上固件身份。")
            if not checked:
                self.clear_display()
                self.busy = True
                self.lock_settings(True)
                self.end_button.configure(state="disabled")
                self.update_save()
                self.status.set("正在检测示波器连接与采集设置……")
                host = self.ip.get().strip()
                profile = self.scope_profile()

                def check():
                    try:
                        result = inspect_scope(host, profile, require_stop=False)
                        self.events.put(("preflight", result))
                    except Exception as error:
                        self.events.put(("preflight_error", str(error)))
                threading.Thread(target=check, daemon=True).start()
                return
            config = dict(ip=self.ip.get().strip(), force=self.force.get(),
                          instrument=instrument_id(self.instrument.get().strip()), volume=str(volume),
                          effects="on" if self.effects.get() else "off",
                          bitstream=self.bitstream.get(),
                          joint=self.capture_mode.get() == "自动联合测量")
            keys.sort(key=lambda key: ((key - 1) % 6, key))
            mode = self.mode.get()
            self.busy = True
            self.lock_settings(True)
            self.start_button.configure(state="disabled")
            self.end_button.configure(state="disabled")
            self.update_save()
            self.status.set("正在后台核对固件与历史记录……")
            def prepare_plan():
                try:
                    config["digest"] = session.read_version(config["bitstream"])
                    conditions = dict(instrument_user_reported=config["instrument"],
                                      volume_user_reported=config["volume"],
                                      effects_user_reported=config["effects"])
                    image = session.image_folder(config["digest"], config["instrument"])
                    summaries = {key: session.analysis_progress(
                        image / f"K{key:02}" / config["force"], conditions, config["joint"])
                        for key in keys}
                    self.events.put(("plan_ready", (config, conditions, image, keys, summaries, mode, count)))
                except Exception as error:
                    self.events.put(("plan_error", str(error)))
            threading.Thread(target=prepare_plan, daemon=True).start()
        except Exception as error:
            messagebox.showerror("无法建立计划", str(error), parent=self.root)

    def finish_plan(self, payload):
        config, conditions, image, keys, summaries, mode, count = payload
        self.busy = False
        try:
            digest, volume = config["digest"], config["volume"]
            initial_counts = {key: len(summaries[key]["usable"]) for key in keys}
            targets = {key: initial_counts[key] + count if mode == "本轮新增" else count
                       for key in keys}
            details = plan_progress_text(keys, initial_counts, targets)
            resume_note = (
                "本轮新增模式：目标已包含现有可用次数；中断后按各键累计目标补齐，不要再次叠加新增次数。"
                if mode == "本轮新增" else
                "累计补齐模式：只补不足目标的次数，已达到目标的键自动跳过。")
            if not messagebox.askokcancel(
                "确认测量条件",
                f"实际烧录文件请人工确认：\n{config['bitstream']}\nSHA256：{digest[:12]}\n"
                "软件不会读取 FPGA 固件；换过烧录文件必须重新选择。\n"
                f"音色 {config['instrument']} / 音量 {volume} / 音效 {config['effects']}\n"
                "CH1 接当前键对应列；CH2 接 DAC 模拟 L；地夹仅接已确认的公共 GND。\n"
                + ("目标只计联合分析可用记录；换键须核对 D0/D1 行线与 D2 列线。\n"
                   if config["joint"] else
                   "目标只计示波器条件性分析可用记录；不需要逻辑分析仪行线。\n")
                + ("自动联合模式会启动逻辑采集并向示波器发送 SINGLE；等提示后只按一次键。\n\n"
                 if config["joint"] else
                 "手动模式只下载 STOP 波形；请自行启动一次采集、按键，再停止。\n\n")
                + details + "\n\n" + resume_note
                + "\n分析可用不代表已经完成小于 5 ms 验收。", parent=self.root):
                self.status.set("已取消建立计划")
                self.lock_settings(False)
                self.start_button.configure(state="normal")
                return
            self.config, self.conditions, self.targets = config, conditions, targets
            self.initial_counts = initial_counts
            self.keys, self.image = keys, image
            self.lock_settings(True)
            self.end_button.configure(state="normal")
            self.log_message(f"版本 {digest[:12]}；顺序：" + ", ".join(f"K{k}" for k in keys))
            self.log_message("累计目标：" + ", ".join(f"K{k}={targets[k]}" for k in keys))
            self.log_message(details)
            self.apply_progress(summaries)
        except Exception as error:
            self.lock_settings(False)
            self.start_button.configure(state="normal")
            messagebox.showerror("无法建立计划", str(error), parent=self.root)
        finally:
            self.update_save()

    def show_wiring(self, key):
        wiring = session.key_wiring(key)
        joint = self.config.get("joint", False) if self.config else self.capture_mode.get() == "自动联合测量"
        text = (f'CH1：第 {wiring["column"]} 列 / FPGA 球位 {wiring["column_ball"]}；'
                'CH2：DAC 模拟 L；地仅接已确认公共 GND。')
        if joint:
            text += (f'\nD0：A 行 {wiring["a_ball"]}；D1：B 行 {wiring["b_ball"]}；'
                     f'D2：同列 {wiring["column_ball"]}。球位不等于排针编号。')
        else:
            text += "\n示波器条件性分析：当前不使用逻辑分析仪 A/B 行通道。"
        if key != self.last_wiring_key and joint and hasattr(self, "owner") and hasattr(self.owner, "scan"):
            self.owner.scan.confirm.set(False)
        if self.last_wiring_key is not None and key != self.last_wiring_key:
            previous = session.key_wiring(self.last_wiring_key)
            changes = []
            if previous["column_ball"] != wiring["column_ball"]:
                changes.append("CH1" + ("、D2" if joint else "") + " 换到当前列")
            if joint and previous["a_ball"] != wiring["a_ball"]:
                changes.append("D0、D1 换到当前 A/B 行")
            notice = "；".join(changes) or "测量接线不变"
            self.log_message(f"K{self.last_wiring_key} → K{key}：{notice}")
            text += "\n本次换键：" + notice
        self.connection.set(text)
        self.last_wiring_key = key

    def refresh(self):
        if not self.config:
            return
        self.refresh_generation += 1
        generation = self.refresh_generation
        config, conditions, image, keys = dict(self.config), dict(self.conditions), self.image, list(self.keys)
        self.busy = True
        self.update_save()
        self.check.configure(state="disabled")
        self.end_button.configure(state="disabled")
        self.status.set("正在后台核对测量进度……")
        def worker():
            try:
                summaries = {key: session.analysis_progress(
                    image / f"K{key:02}" / config["force"], conditions, config["joint"])
                    for key in keys}
                self.events.put(("progress_ready", (generation, summaries)))
            except Exception as error:
                self.events.put(("progress_error", (generation, str(error))))
        threading.Thread(target=worker, daemon=True).start()

    def apply_progress(self, summaries):
        if not self.config:
            return
        self.current = None
        self.tree.delete(*self.tree.get_children())
        for key in self.keys:
            summary = summaries[key]
            done, number = summary["usable"], summary["next_number"]
            pending = len(done) < self.targets[key]
            if pending and self.current is None:
                self.current = (key, number)
            self.tree.insert("", "end", iid=str(key), values=(
                f"K{key}", len(summary["saved"]), len(done), len(summary["pending"]), self.targets[key],
                "待补分析可用记录" if pending else "可用目标已达到"))
        self.stopped.set(False)
        if self.current:
            key, number = self.current
            self.key_label.set(f"K{key} · 第 {number} 号记录")
            self.show_wiring(key)
            self.tree.selection_set(str(key))
            self.tree.see(str(key))
            self.check.configure(state="normal")
            self.status.set("等待联合采集；先核对当前行列接线" if self.config["joint"] else
                            "自行启动单次采集，按一次目标键；停止后保存")
        else:
            self.key_label.set("本轮测量已完成")
            self.status.set("当前口径的分析可用目标已达到；不等于 5 ms 达标判定")
            self.check.configure(state="disabled")
        self.update_save()

    def update_save(self):
        enabled = self.config and self.current and self.stopped.get() and not self.busy
        self.save_button.configure(state="normal" if enabled else "disabled")
        self.analyze_button.configure(state="disabled" if self.busy else "normal")
        for radio in getattr(self, "capture_modes", ()):
            radio.configure(state="disabled" if self.busy or self.config else "normal")
        if hasattr(self, "joint_button"):
            self.joint_button.configure(
                state="normal" if self.config and self.current and not self.busy else "disabled")

    def analyze_saved(self):
        if self.busy:
            return
        selected = pick_record(self.root, "latency", "选择要分析的延迟记录 trial.json")
        if not selected:
            return
        self.latest_report = None
        self.latest_spectrum = None
        self.latest_folder = Path(selected)
        self.busy = True
        self.stopped.set(False)
        self.start_button.configure(state="disabled")
        self.end_button.configure(state="disabled")
        self.update_save()
        self.status.set("离线分析原始数据，正在生成频谱、B 细节和延迟报告……")

        def worker():
            try:
                from latency_spectrum import generate as spectrum
                from review_latency_evidence import generate as review
                folder = Path(selected)
                self.events.put(("spectrum_ready", str(spectrum(folder))))
                self.events.put(("latency_ready", str(review(folder))))
                self.events.put(("offline_done", "已有记录分析完成；请打开延迟报告查看假设与误差。"))
            except Exception as error:
                self.events.put(("offline_error", str(error)))
        threading.Thread(target=worker, daemon=True).start()

    def save(self):
        if self.busy or not self.current or not self.stopped.get():
            return
        self.latest_report = None
        self.latest_spectrum = None
        self.latest_folder = None
        self.busy = True
        self.update_save()
        self.check.configure(state="disabled")
        self.end_button.configure(state="disabled")
        self.status.set("正在保存截图和两路原始数据，请勿操作示波器……")
        self.transfer_bar["value"] = 0
        self.transfer_text.set("正在检查并读取截图……")
        key, number = self.current
        config = dict(self.config)
        threading.Thread(target=self.capture, args=(config, key, number), daemon=True).start()

    def scope_profile(self):
        return "latency_joint" if self.capture_mode.get() == "自动联合测量" else "latency"

    def capture(self, config, key, number):
        try:
            if session.read_version(config["bitstream"]) != config["digest"]:
                raise RuntimeError("版本记录发生变化，请重新确认板上版本。")
            check = inspect_scope(config["ip"], "latency_joint" if config.get("joint") else "latency")
            self.events.put(("log", check.text()))
            if check.errors:
                raise RuntimeError(check.text())
            # pythonw has no usable console; explicitly use python for the child.
            executable = str(Path(sys.executable).with_name("python.exe")) if os.name == "nt" else sys.executable
            script = "capture_joint_trial.py" if config.get("joint") else "capture_key_trial.py"
            command = [executable, "-u", str(session.ROOT / "tools" / script),
                       "--key", str(key), "--trial", str(number)]
            if config.get("joint"):
                command.extend(["--logic-rate", str(config["logic_rate"]),
                                "--analysis-margin-us", str(config["analysis_margin_us"]),
                                "--clock-ppm", str(config["clock_ppm"])])
            for name in ("ip", "force", "instrument", "volume", "effects"):
                command.extend(["--" + name, config[name]])
            command.extend(["--bitstream", config["bitstream"], "--expected-sha256", config["digest"]])
            environment = dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8")
            from collections import deque
            recent_output = deque(maxlen=12)
            validation_warning = None
            with subprocess.Popen(command, cwd=session.ROOT, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                                  errors="replace", env=environment,
                                  creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0) as process:
                for line in process.stdout:
                    if line.strip():
                        recent_output.append(line.strip())
                    if line.startswith("JOINT_READY"):
                        self.events.put(("joint_ready", line.strip()))
                    elif line.startswith("JOINT_ARMING"):
                        self.events.put(("joint_arming", line.strip()))
                    elif line.startswith("JOINT_CAPTURED"):
                        self.events.put(("joint_captured", line.strip()))
                    elif line.startswith("JOINT_VALIDATION_WARNING "):
                        detail = json.loads(line[len("JOINT_VALIDATION_WARNING "):])
                        validation_warning = (
                            "原始数据及示波器截图已保存，联合验证未通过，不能判定延迟小于 5 ms。\n\n"
                            "阶段：" + detail["stage"] + "\n原因：" + detail["reason"]
                            + "\n\n已有记录可用于离线排查，无需仅因该提示重新采集。")
                        if detail.get("diagnostic_file"):
                            validation_warning += "\n诊断文件：" + detail["diagnostic_file"]
                        if detail.get("action"):
                            validation_warning += "\n\n下一步：" + detail["action"]
                        if detail.get("signal_summary"):
                            validation_warning += "\n\n数字波形排查（不是达标结果）：\n" + detail["signal_summary"]
                        if detail.get("signal_report"):
                            self.events.put(("signal_diagnostic_ready", detail["signal_report"]))
                        self.events.put(("log", validation_warning))
                    elif line.startswith("TRANSFER "):
                        self.events.put(("transfer", line))
                    elif line.startswith("SPECTRUM processing"):
                        self.events.put(("spectrum_processing", "原始数据已保存，正在计算音频频谱……"))
                    elif line.startswith("Spectrum: "):
                        self.events.put(("spectrum_ready", line[len("Spectrum: "):].strip()))
                    elif line.startswith("SPECTRUM_WARNING"):
                        self.events.put(("spectrum_warning", line.strip()))
                    elif line.startswith("LATENCY processing"):
                        self.events.put(("latency_processing", (
                            "正在用数字行列定位 B，并独立分析模拟起音……" if config.get("joint")
                            else "正在生成 B 触点细节与延迟报告……")))
                    elif line.startswith("Latency report: "):
                        self.events.put(("latency_ready", line[len("Latency report: "):].strip()))
                    elif line.startswith("LATENCY_WARNING"):
                        self.events.put(("latency_warning", line.strip()))
                    elif line.startswith("Saved trial: "):
                        self.events.put(("folder_ready", line[len("Saved trial: "):].strip()))
                    else:
                        self.events.put(("log", line))
                if process.wait():
                    reason = recent_output[-1] if recent_output else "子进程未返回详细错误。"
                    raise RuntimeError(("联合测量失败" if config.get("joint") else "保存失败")
                                       + "：\n" + reason
                                       + "\n\n已产生的文件会保留；完整错误见运行日志。")
            conditions = dict(instrument_user_reported=config["instrument"],
                              volume_user_reported=config["volume"], effects_user_reported=config["effects"])
            folder = session.image_folder(config["digest"], config["instrument"]) / f"K{key:02}" / config["force"]
            done, _ = session.progress(folder, conditions)
            if number not in done:
                raise RuntimeError("未找到完整记录，请检查数据目录。")
            summary = session.analysis_progress(folder, conditions, joint=bool(config.get("joint")))
            if number not in summary["usable"] and not validation_warning:
                validation_warning = (
                    f"K{key} / {number:03} 原始数据及截图已保存，但"
                    + ("联合分析" if config.get("joint") else "示波器条件性分析")
                    + "未得到可用结果，不计入目标次数；当前键保留待补状态。\n"
                    "原因：" + saved_analysis_failure(folder / f"trial_{number:03}")
                    + "\n\n这不是延迟超标判定；原始数据已保留，可先离线复核。")
            self.events.put(("saved_unverified", validation_warning) if validation_warning else
                            ("success", f"K{key} / {number:03} 已保存，已计入当前口径分析可用次数。"))
        except Exception as error:
            self.events.put(("error", str(error)))

    def poll(self):
        try:
            # Bound UI work per tick even while a worker produces many events.
            for _ in range(80):
                kind, text = self.events.get_nowait()
                if kind == "plan_ready":
                    self.finish_plan(text)
                    continue
                if kind == "plan_error":
                    self.busy = False
                    self.lock_settings(False)
                    self.start_button.configure(state="normal")
                    self.update_save()
                    self.status.set("计划未建立，详见日志")
                    self.log_message(text)
                    messagebox.showerror("无法建立计划", text, parent=self.root)
                    continue
                if kind in ("progress_ready", "progress_error"):
                    generation, payload = text
                    if generation != self.refresh_generation or not self.config:
                        continue
                    self.busy = False
                    self.end_button.configure(state="normal")
                    if kind == "progress_ready":
                        previous_status = self.status.get()
                        self.apply_progress(payload)
                        if previous_status != "正在后台核对测量进度……":
                            self.status.set(previous_status)
                    else:
                        self.log_message(payload)
                        self.status.set("进度核对失败，请查看日志")
                        self.update_save()
                    continue
                if kind == "joint_arming":
                    self.status.set(text.removeprefix("JOINT_ARMING "))
                    self.transfer_text.set("确认启动状态，请勿按键")
                    self.log_message(text)
                    continue
                if kind == "joint_ready":
                    self.status.set(text.removeprefix("JOINT_READY "))
                    self.log_message(text)
                    self.hide_press_prompt()
                    if self.current:
                        self.press_prompt = PressPrompt(self.root, self.current[0])
                    self.transfer_text.set("等待按一次目标键")
                    continue
                elif kind == "joint_captured":
                    self.hide_press_prompt()
                    self.status.set("已触发，正在保存，请勿再次按键")
                    self.transfer_text.set("已触发，正在保存")
                    self.log_message(text)
                    continue
                elif kind == "folder_ready":
                    self.latest_folder = Path(text)
                    self.log_message("本次记录目录：" + text)
                    self.log_message("示波器原屏：" + str(screen_file(self.latest_folder, "latency")))
                    continue
                if kind == "latency_processing":
                    self.status.set(text)
                    self.transfer_text.set("100% · 正在分析延迟")
                    continue
                if kind == "latency_ready":
                    self.latest_report = Path(text)
                    self.log_message("已生成延迟报告：" + text)
                    continue
                if kind == "signal_diagnostic_ready":
                    self.latest_report = Path(text)
                    self.log_message("已生成扫描信号诊断报告（未作达标判定）：" + text)
                    continue
                if kind == "latency_warning":
                    self.log_message(text)
                    continue
                if kind in ("offline_done", "offline_error"):
                    self.busy = False
                    self.start_button.configure(state="disabled" if self.config else "normal")
                    self.end_button.configure(state="normal" if self.config else "disabled")
                    if self.config:
                        self.refresh()
                    self.update_save()
                    self.status.set(text)
                    self.log_message(text)
                    if kind == "offline_error":
                        messagebox.showerror("离线分析失败", text, parent=self.root)
                    continue
                if kind == "spectrum_processing":
                    self.status.set(text)
                    self.transfer_text.set("100% · 正在生成频谱")
                    continue
                if kind == "spectrum_ready":
                    self.latest_spectrum = Path(text)
                    self.log_message("已生成音频频谱：" + text)
                    continue
                if kind == "spectrum_warning":
                    self.log_message(text)
                    messagebox.showwarning("频谱生成失败", "原始数据已保存，频谱生成失败。详见日志。",
                                           parent=self.root)
                    continue
                if kind == "transfer":
                    self.transfer_bar.stop()
                    self.transfer_bar.configure(mode="determinate", maximum=100)
                    _, channel, done, total = text.split()
                    channel, done, total = int(channel), int(done), int(total)
                    percent = ((channel - 1) + done / total) * 50
                    self.transfer_bar["value"] = percent
                    self.transfer_text.set(f"CH{channel}：{done:,}/{total:,} 点 · 总计 {percent:.1f}%")
                    continue
                if kind in ("preflight", "preflight_error"):
                    self.busy = False
                    self.lock_settings(False)
                    self.end_button.configure(state="disabled")
                    self.config = None
                    self.current = None
                    self.update_save()
                    if kind == "preflight" and not text.errors:
                        if not text.warnings or messagebox.askokcancel(
                                "设置建议：仍可继续", "\n".join(text.warnings) + "\n\n仍按当前设置继续？",
                                parent=self.root):
                            self.start(checked=True)
                        else:
                            self.status.set("已取消，未建立计划")
                        self.log_message(text.text())
                    else:
                        detail = text.text() if kind == "preflight" else (
                            "连接失败，请检查网线、当前 IP、网段和示波器电源。\n" + text)
                        self.log_message(detail)
                        self.status.set("连接或设置检查未通过，未建立计划")
                        messagebox.showerror("示波器检查未通过", detail, parent=self.root)
                    continue
                self.log_message(text)
                if kind in ("success", "error", "saved_unverified"):
                    self.hide_press_prompt()
                    self.transfer_bar.stop()
                    self.transfer_bar.configure(mode="determinate", maximum=100)
                    self.busy = False
                    self.end_button.configure(state="normal")
                    self.refresh()
                    if kind == "error":
                        self.transfer_text.set("采集流程未完成，详见日志")
                        self.status.set("采集流程未完成；已产生的文件保留，请查看具体原因")
                        messagebox.showerror("采集流程未完成", text, parent=self.root)
                    else:
                        self.transfer_bar["value"] = 100
                        self.transfer_text.set("100% · 截图、原始数据已保存")
                        if kind == "saved_unverified":
                            joint = bool(self.config.get("joint")) if self.config else "联合" in text
                            label = "联合验证未通过" if joint else "示波器分析未通过"
                            self.status.set(f"数据已保存，{label}；不计分析可用次数，不能判定达标")
                            if hasattr(self, "result_tabs"):
                                self.result_tabs.select(1)
                            messagebox.showwarning("数据已保存，" + label, text, parent=self.root)
        except queue.Empty:
            pass
        self.poll_id = self.root.after(100, self.poll)

    def hide_press_prompt(self):
        if self.press_prompt is not None:
            self.press_prompt.close()
            self.press_prompt = None

    def end(self):
        if self.busy:
            return
        if self.current and not messagebox.askyesno("结束本轮", "结束当前计划？已有数据会保留。", parent=self.root):
            return
        self.config = None
        self.current = None
        self.stopped.set(False)
        self.check.configure(state="disabled")
        self.lock_settings(False)
        self.update_save()
        self.clear_display()
        self.status.set("本轮已结束，数据保留")

    def open_folder(self):
        try:
            session.BASE.mkdir(parents=True, exist_ok=True)
            os.startfile(session.BASE)
        except OSError as error:
            messagebox.showerror("无法打开目录", str(error), parent=self.root)

    def open_spectrum(self):
        open_artifact(self.root, "latency", "spectrum", self.latest_spectrum)

    def open_screen(self):
        target = screen_file(self.latest_folder, "latency") if self.latest_folder else None
        open_artifact(self.root, "latency", "screen", target)

    def open_trial(self):
        if not self.latest_folder or not self.latest_folder.is_dir():
            selected = pick_record(self.root, "latency", "选择要打开目录的延迟记录 trial.json")
            if not selected:
                return
            self.latest_folder = Path(selected)
        try:
            os.startfile(self.latest_folder)
        except OSError as error:
            messagebox.showerror("无法打开目录", str(error), parent=self.root)

    def open_report(self):
        open_artifact(self.root, "latency", "report", self.latest_report)

    def close(self):
        if self.busy:
            messagebox.showwarning("正在下载", "请等本次下载结束再关闭窗口。", parent=self.root)
            return
        self.root.destroy()


def create_root():
    if os.name == "nt":
        import ctypes
        try:
            ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
        except (AttributeError, OSError):
            pass
    root = tk.Tk()
    root.tk.call("tk", "scaling", 96 / 72)
    return root


def main():
    root = create_root()
    LatencyApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()

"""Typed local storage and native file selection for measurement evidence."""

import json
import os
from pathlib import Path
from tkinter import filedialog, messagebox

ROOT = Path(__file__).resolve().parents[1]
KINDS = ("polyphony", "latency", "lrck", "logic", "evidence")


def directory(group, kind=None):
    path = ROOT / "firmware" if group == "firmware" else ROOT / "measurements" / group
    return path / kind if kind else path


def prepare():
    directory("firmware").mkdir(parents=True, exist_ok=True)
    for kind in KINDS:
        for group in ("raw", "screens", "reports"):
            if kind != "evidence" or group == "reports":
                directory(group, kind).mkdir(parents=True, exist_ok=True)


def record_key(record, kind):
    record = Path(record).resolve()
    roots = [directory("raw", kind)]
    legacy = {"latency": "full_key_latency", "lrck": "lrck", "logic": "joint_logic"}
    if kind in legacy:
        roots.append(ROOT / "measurements" / legacy[kind])
    if kind == "polyphony":
        roots.append(ROOT / "measurements")
    for root in roots:
        if record.is_relative_to(root.resolve()):
            return record.relative_to(root.resolve())
    return None


def report_folder(record, kind):
    key = record_key(record, kind)
    return directory("reports", kind) / key if key is not None else Path(record)


def screen_file(record, kind, writing=False):
    record = Path(record)
    key = record_key(record, kind)
    target = directory("screens", kind) / key / "screen.bmp" if key is not None else record / "screen.bmp"
    if not writing and not target.is_file() and (record / "screen.bmp").is_file():
        return record / "screen.bmp"
    if writing:
        target.parent.mkdir(parents=True, exist_ok=True)
    return target


def raw_record_for_report(path, kind):
    path = Path(path).resolve()
    base = directory("reports", kind).resolve()
    if path.is_relative_to(base):
        relative = path.relative_to(base)
        parts = relative.parts
        if kind == "latency" and "scan_validation" in parts:
            parts = parts[:parts.index("scan_validation")]
        elif kind == "latency" and "scan_diagnostics" in parts:
            parts = parts[:parts.index("scan_diagnostics")]
        elif kind == "latency" and "evidence" in parts:
            parts = parts[:parts.index("evidence")]
        else:
            parts = parts[:-1]
        return directory("raw", kind).joinpath(*parts)
    return path.parents[2] if kind == "latency" and "scan_validation" in path.parts else path.parent


def relative_link(target, page_folder):
    return Path(os.path.relpath(target, page_folder)).as_posix()


def validate_record(folder, kind, all_voices=False):
    folder = Path(folder)
    manifest = "trial.json" if kind == "latency" else "capture.json"
    data = json.loads((folder / manifest).read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("记录参数格式错误。")
    if kind == "latency":
        valid = data.get("status") == "complete"
        files = ("ch1.bin", "ch2.bin", "metadata.json")
    elif kind == "lrck":
        valid = data.get("kind") == "lrck" and data.get("status") == "complete"
        files = ("raw.bin",)
    elif kind == "polyphony":
        valid = data.get("kind") == "DAC_OUTPUT_SCOPE_CAPTURE" and data.get("complete")
        files = ("raw.bin",)
        if all_voices and data.get("operator_declared_selection") != 0:
            raise ValueError("必须选择全部开启（ALL）的复音记录。")
    else:
        raise ValueError("不支持的原始记录类型。")
    if not valid or any(not (folder / name).is_file() for name in files):
        raise ValueError("不是完整的对应测量记录，或缺少原始数据文件。")
    return folder


def pick_record(parent, kind, title, all_voices=False):
    prepare()
    name = "trial.json" if kind == "latency" else "capture.json"
    selected = filedialog.askopenfilename(
        parent=parent, title=title, initialdir=str(directory("raw", kind)),
        filetypes=(("原始记录参数 " + name, name),))
    if not selected:
        return None
    try:
        path = Path(selected)
        if path.name != name:
            raise ValueError("请选择 " + name + "，不要选择分析结果 JSON。")
        return validate_record(path.parent, kind, all_voices)
    except (OSError, ValueError, KeyError) as error:
        messagebox.showerror("记录选择无效", str(error), parent=parent)
        return None


def pick_artifact(parent, kind, artifact, current=None):
    prepare()
    if artifact == "screen":
        group, title, types = "screens", "选择示波器原屏", (("示波器原屏 BMP", "*.bmp"),)
    elif artifact == "spectrum":
        group, title, types = "reports", "选择音频频谱图", (("频谱图 PNG", "*.png"),)
    else:
        group, title, types = "reports", "选择分析报告", (("分析报告 HTML", "*.html"),)
    base = directory(group, kind)
    current = Path(current) if current else None
    initial = current.parent if current and current.is_file() and current.is_relative_to(base) else base
    selected = filedialog.askopenfilename(parent=parent, title=title,
                                           initialdir=str(initial), filetypes=types)
    return Path(selected) if selected else None


def open_artifact(parent, kind, artifact, current=None):
    selected = pick_artifact(parent, kind, artifact, current)
    if selected:
        try:
            os.startfile(selected)
        except OSError as error:
            messagebox.showerror("无法打开文件", str(error), parent=parent)
    return selected


def pick_firmware(parent, current=None):
    prepare()
    return filedialog.askopenfilename(
        parent=parent, title="选择实际烧录的 .fs 文件（人工确认）",
        initialdir=str(directory("firmware")), filetypes=(("FPGA 固件 .fs", "*.fs"),))

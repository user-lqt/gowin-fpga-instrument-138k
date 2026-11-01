"""Interactive front end for manually stopped latency captures."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from functools import lru_cache
from datetime import datetime
from measurement_files import directory, screen_file, report_folder


ROOT = Path(__file__).resolve().parents[1]
BASE = directory("raw", "latency")
VERSION = BASE / "current_board_version.json"


def describe_version(bitstream):
    path = Path(bitstream).resolve()
    if not path.is_file() or path.suffix.lower() != ".fs":
        raise ValueError("请选择实际烧录的 .fs 文件。")
    stat = path.stat()
    return {
        "recorded_date": datetime.now().astimezone().date().isoformat(),
        "confirmation_source": "用户在延迟测量界面选择并确认；未从 FPGA 读回。",
        "bitstream_path": str(path),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest().upper(),
        "size_bytes": stat.st_size,
        "file_last_write_time_local": datetime.fromtimestamp(stat.st_mtime).astimezone().isoformat(),
        "scope": "本记录仅对应人工选择文件；软件不能自动核实实际烧录版本。",
    }


def read_version(bitstream=None):
    if bitstream:
        return describe_version(bitstream)["sha256"]
    version = json.loads(VERSION.read_text(encoding="utf-8"))
    actual = hashlib.sha256(Path(version["bitstream_path"]).read_bytes()).hexdigest()
    if actual.upper() != version["sha256"].upper():
        raise RuntimeError("烧录文件已变化，与已确认版本不符。请先重新确认版本。")
    return actual.upper()


def version_correction(folder):
    folder = Path(folder)
    path = folder / "version_correction.json"
    if not path.exists():
        return None
    correction = json.loads(path.read_text(encoding="utf-8"))
    for name, field in (("trial.json", "original_trial_sha256"),
                        ("metadata.json", "original_metadata_sha256")):
        if hashlib.sha256((folder / name).read_bytes()).hexdigest().upper() != correction[field].upper():
            raise ValueError("版本更正文件与原始记录不一致：" + str(folder))
    return correction


def parse_keys(text):
    if text.strip().lower() in ("all", "全部"):
        return list(range(1, 25))
    keys = []
    for token in re.split(r"[\s,，]+", text.strip()):
        if not token:
            continue
        match = re.fullmatch(r"[kK]?(\d+)(?:-[kK]?(\d+))?", token)
        if not match:
            raise ValueError("请输入 all、1-24 或 1,2,7 等按键编号。")
        start = int(match[1])
        end = int(match[2]) if match[2] else start
        if not 1 <= start <= end <= 24:
            raise ValueError("按键范围必须在 1～24，且起点不大于终点。")
        keys.extend(range(start, end + 1))
    if not keys:
        raise ValueError("至少选择一个按键。")
    return list(dict.fromkeys(keys))


def positive_integer(text):
    try:
        number = int(text)
    except ValueError:
        raise ValueError("次数必须是正整数。") from None
    if number < 1:
        raise ValueError("次数必须是正整数。")
    return number


def parse_mode(text):
    if text not in ("1", "2"):
        raise ValueError("请输入 1 或 2。")
    return text


def ask(prompt, parser, default):
    while True:
        answer = input(prompt).strip()
        if answer.lower() == "q":
            raise EOFError
        try:
            return parser(answer or default)
        except ValueError as error:
            print(error)


def instrument_id(value):
    return {"钢琴": "piano", "吉他": "guitar", "编钟": "bianzhong",
            "钟琴": "bianzhong", "bell": "bianzhong"}.get(value, value)


def image_folder(digest, instrument="piano", base=None):
    name = "firmware_" + digest[:12]
    timbre = instrument_id(instrument)
    if timbre in ("guitar", "bianzhong"):
        name += "_" + timbre
    return (BASE if base is None else Path(base)) / name


def progress(folder, conditions=None):
    complete = []
    used = []
    for path in folder.glob("trial_*"):
        match = re.fullmatch(r"trial_(\d+)(_video_test)?", path.name)
        if not match:
            continue
        suffix = match[1]
        used.append(int(suffix))
        # Demo captures reserve their number without filling the historical plan.
        if match[2]:
            continue
        try:
            info = json.loads((path / "trial.json").read_text(encoding="utf-8"))
            correction = version_correction(path)
            if correction:
                corrected_hash = correction["corrected_version"]["sha256"].upper()
                if folder.parent.parent.name.upper() not in (
                        "IMAGE_" + corrected_hash[:12], "FIRMWARE_" + corrected_hash[:12]):
                    continue
        except (OSError, ValueError):
            continue
        if conditions and any(
                (instrument_id(info.get(name)) != instrument_id(value)
                 if name == "instrument_user_reported" else info.get(name) != value)
                for name, value in conditions.items()):
            continue
        required = ("metadata.json", "ch1.bin", "ch2.bin")
        if info.get("status") == "complete" and all(
            (path / name).is_file() and (path / name).stat().st_size > 0
            for name in required
        ) and screen_file(path, "latency").is_file():
            complete.append(int(suffix))
    return sorted(complete), max(used, default=0) + 1


def key_wiring(key):
    if not 1 <= key <= 24:
        raise ValueError("按键范围必须在 1～24。")
    column = (key-1) % 6
    group = (key-1) // 6
    rows = (("E14", "E13"), ("C15", "C14"), ("B13", "C13"), ("A14", "A13"))
    return dict(column=column+1, column_ball=("B16", "B15", "A16", "A15", "A20", "B20")[column],
                a_ball=rows[group][0], b_ball=rows[group][1])


@lru_cache(maxsize=1024)
def _file_digest(path, size, modified_ns):
    with Path(path).open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    stat = Path(path).stat()
    if (stat.st_size, stat.st_mtime_ns) != (size, modified_ns):
        raise ValueError("证据文件正在变化，请等待保存完成。")
    return digest


def file_digest(path):
    path = Path(path)
    stat = path.stat()
    return _file_digest(str(path.resolve()), stat.st_size, stat.st_mtime_ns)


def analysis_progress(folder, conditions=None, joint=False):
    """Count saved data separately from matching, successfully rendered analyses."""
    folder = Path(folder)
    saved, number = progress(folder, conditions)
    usable = []
    for index in saved:
        trial = folder / f"trial_{index:03}"
        try:
            meta = json.loads((trial / "metadata.json").read_text(encoding="utf-8"))
            hashes = {ch: meta[ch]["sha256"].lower() for ch in ("CH1", "CH2")}
            if any((trial/f"ch{ch[-1]}.bin").stat().st_size !=
                   int(float(meta[ch]["preamble"].split(",")[2])) for ch in hashes):
                continue
            if any(file_digest(trial/f"ch{ch[-1]}.bin") != hashes[ch] for ch in hashes):
                continue
        except (OSError, ValueError, KeyError, IndexError, TypeError, AttributeError):
            continue
        base = report_folder(trial, "latency")
        if joint:
            candidates = sorted(base.glob("scan_validation/verification_*/analysis.json"))
        else:
            candidates = [base/"evidence/review.json",
                          *sorted(base.glob("evidence/review_*/review.json"))]
        for path in candidates:
            try:
                result = json.loads(path.read_text(encoding="utf-8"))
                expected_kind = "joint_scan_latency" if joint else "latency_evidence"
                if result.get("kind") != expected_kind or not path.with_name("report.html").is_file():
                    continue
                if {ch: result["raw_sha256"][ch].lower() for ch in hashes} != hashes:
                    continue
                if joint:
                    csv_path = path.with_name("logic.csv")
                    if (not csv_path.is_file() or
                            file_digest(csv_path) != result["logic_csv_sha256"]):
                        continue
                elif not result.get("raw_hashes_verified"):
                    continue
                usable.append(index)
                break
            except (OSError, ValueError, KeyError, TypeError, AttributeError):
                continue
    return dict(saved=saved, usable=usable, pending=sorted(set(saved)-set(usable)), next_number=number)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ip", default="169.254.229.90")
    parser.add_argument("--keys", nargs="+", help="all、1-24 或指定编号，例如 1 2 7")
    count = parser.add_mutually_exclusive_group()
    count.add_argument("--target", type=int, help="每键累计完整记录目标，适合中断后补齐")
    count.add_argument("--add", type=int, help="本轮每键新增次数；重新启动会重新计算目标")
    parser.add_argument("--force", choices=("soft", "medium", "hard"), default="medium")
    parser.add_argument("--instrument", default="piano")
    parser.add_argument("--volume", type=int, choices=range(128), default=127)
    parser.add_argument("--effects", default="off")
    parser.add_argument("--plan", action="store_true", help="仅显示进度，不连接仪器")
    args = parser.parse_args()
    try:
        if args.keys:
            keys = parse_keys(" ".join(args.keys))
        elif args.plan:
            keys = list(range(1, 25))
        else:
            keys = ask("测哪些键？all=全部24键，也可输入 1-6 或 1,2,7 [all]：", parse_keys, "all")
        if args.target is not None:
            positive_integer(str(args.target))
        elif args.add is not None:
            positive_integer(str(args.add))
        elif args.plan:
            args.target = 3
        else:
            mode = ask("1=累计补齐，2=本轮新增 [1]：",
                       parse_mode, "1")
            number = ask("每键次数（正整数）[3]：", positive_integer, "3")
            if mode == "1":
                args.target = number
            else:
                args.add = number
    except ValueError as error:
        parser.error(str(error))
    # Group by column so a full keyboard run needs only six column connections.
    keys = sorted(keys, key=lambda key: ((key - 1) % 6, key))
    digest = read_version()
    image = image_folder(digest, args.instrument)
    print(f"版本：{digest[:12]}")
    print(f"示波器地址：{args.ip}:5555（此前地址，请确认当前仍适用）")
    print(f"条件：{args.instrument}，音量 {args.volume}，音效 {args.effects}，力度 {args.force}")
    conditions = {
        "instrument_user_reported": args.instrument,
        "volume_user_reported": str(args.volume),
        "effects_user_reported": args.effects,
    }
    targets = {}
    for key in keys:
        done, _ = progress(image / f"K{key:02}" / args.force, conditions)
        targets[key] = len(done) + args.add if args.add is not None else args.target
        print(f"K{key}: 同条件完整记录 {len(done)}，累计目标 {targets[key]}，编号 {done}")
    print("按列安排测量顺序：" + " → ".join(f"K{key}" for key in keys))
    if args.add is not None:
        print("注意：新增模式重启后会重新增加目标；中断后请用累计模式输入本次显示的目标。")
    if args.plan:
        return 0
    print("\nCH1 接当前键对应列，CH2 保持 DAC 模拟 L；地夹仅接已确认的公共 GND。")
    print("更换列线前先停止采集；同列无需换线。FPGA 球位不等于排针编号。")
    print("本程序不发送 RUN/SINGLE，不改触发、量程或时基；下载时不要操作示波器。")
    print("文件版本校验不能读取 FPGA，不能代替确认板上实际烧录版本。")
    if input("确认板上版本、上述条件及接线无误，输入 yes 开始；其他输入退出：").strip().lower() != "yes":
        return 0
    previous_column = None
    for key in keys:
        folder = image / f"K{key:02}" / args.force
        while True:
            done, number = progress(folder, conditions)
            if len(done) >= targets[key]:
                break
            column = (key - 1) % 6
            if column != previous_column:
                ball = ("B16", "B15", "A16", "A15", "A20", "B20")[column]
                print(f"\n下一键 K{key}，列 {column + 1}，约束 FPGA 球位 {ball}。")
                print("先核对已经确认过的物理列接线；不要按球位名称猜测排针位置。")
                previous_column = column
            print(f"\n准备 K{key}，保存编号 {number:03}，同条件完整记录 {len(done)}/{targets[key]}。")
            answer = input("手动 SINGLE → 按键 → 确认 STOP；完成后回车保存，q 回车退出：").strip().lower()
            if answer == "q":
                return 0
            if answer:
                print("未开始保存。请回车保存，或输入 q 退出。")
                continue
            if read_version() != digest:
                raise RuntimeError("会话期间版本记录改变，已停止。")
            print("正在下载截图和两路原始数据，请勿操作示波器，可能需要约一分钟……", flush=True)
            command = [
                sys.executable, str(ROOT / "tools/capture_key_trial.py"),
                "--ip", args.ip, "--key", str(key), "--force", args.force,
                "--trial", str(number), "--instrument", args.instrument,
                "--volume", str(args.volume), "--effects", args.effects,
            ]
            result = subprocess.run(command, cwd=ROOT, check=False)
            if result.returncode:
                print("保存失败，已停止会话；失败目录保留，不覆盖。解决错误后重新运行即可。")
                print("重新运行后须重新采集，不能把同一条停止波形当成一次新测量。")
                return 1
            done_after, _ = progress(folder, conditions)
            if number not in done_after:
                raise RuntimeError("采集脚本结束，但未找到完整记录。请检查目录。")
            print(f"已保存 K{key} / {number:03}。下一次必须重新 SINGLE 并重新按键，勿重复保存同一波形。")
    print(f"\n本组目标已完成。数据目录：{image}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        print("\n会话退出；若下载中断，请保留并检查未完成目录。")
        sys.exit(130)
    except Exception as error:
        print(f"\n错误：{error}", file=sys.stderr)
        sys.exit(1)

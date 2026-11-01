"""Preserve one manually stopped two-channel acquisition and its screen."""

import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import socket
import math
import time
from measurement_files import directory, screen_file


def exact(stream, count):
    data = bytearray()
    while len(data) < count:
        part = stream.read(count - len(data))
        if not part:
            raise EOFError("Incomplete transfer")
        data.extend(part)
    return bytes(data)


class BinaryTransferError(ValueError):
    """The connection must not be reused after an unverified binary response."""


def block(stream, limit):
    try:
        return read_block(stream, limit)
    except (OSError, EOFError, ValueError) as error:
        raise BinaryTransferError(
            f"二进制传输未完成或格式异常，停止使用本次连接：{error}") from error


def read_block(stream, limit):
    if exact(stream, 1) != b"#":
        raise ValueError("Missing SCPI block header")
    digit = exact(stream, 1)
    if digit not in b"123456789":
        raise ValueError("Invalid SCPI length header")
    size = int(exact(stream, int(digit)))
    if not 0 < size <= limit:
        raise ValueError(f"Unexpected block length: {size}")
    data = exact(stream, size)
    if stream.readline() not in (b"\n", b"\r\n"):
        raise ValueError("Invalid block terminator")
    return data


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2), encoding="utf-8")


def restore_transfer(send, original, metadata, *, safe=True):
    if not original:
        return
    if not safe:
        metadata["transfer_restore"] = {
            "status": "skipped",
            "reason": "连接中断或数据流同步未确认，未发送恢复命令；下次下载会重新设置传输参数。",
        }
        return
    try:
        send(":WAV:STAR 1")
        for name in ("SOUR", "MODE", "FORM", "STOP", "STAR"):
            send(f":WAV:{name} {original[name]}")
        metadata["transfer_restore"] = {"status": "commands_sent"}
    except Exception as error:
        metadata["transfer_restore"] = {"status": "error", "error": repr(error)}
        print(f"TRANSFER_RESTORE_WARNING 恢复传输设置失败，原始下载结果另行保留：{error}",
              flush=True)


def verify_capture(query, channel, preamble):
    expected = {
        ":TRIG:STAT?": "STOP",
        ":WAV:SOUR?": f"CHAN{channel}",
        ":WAV:MODE?": "RAW",
        ":WAV:FORM?": "BYTE",
        ":WAV:PRE?": preamble,
    }
    observed = {command: query(command) for command in expected}
    if observed != expected:
        differences = {command: {"expected": expected[command], "observed": value}
                       for command, value in observed.items()
                       if value != expected[command]}
        raise RuntimeError("采集状态或波形参数改变，停止下载: " +
                           json.dumps(differences, ensure_ascii=False))


def prepare_channel(send, query, channel, entry, metadata):
    """Wait for stable RAW transfer metadata before requesting any binary data."""
    acquisition = {name: metadata[name] for name in (
        ":ACQ:MDEP?", ":ACQ:SRAT?", ":TIM:SCAL?", ":TIM:OFFS?")}
    history = entry.setdefault("preamble_checks", [])
    for attempt in range(3):
        if query(":TRIG:STAT?") != "STOP":
            raise RuntimeError("准备下载时采集状态已改变；未请求波形数据。")
        if {name: query(name) for name in acquisition} != acquisition:
            raise RuntimeError("准备下载时存储深度、采样率或水平设置已改变；未请求波形数据。")
        send(f":WAV:SOUR CHAN{channel}")
        send(":WAV:MODE RAW")
        send(":WAV:FORM BYTE")
        first = query(":WAV:PRE?")
        time.sleep(.15)
        second = query(":WAV:PRE?")
        state = {name: query(name) for name in (
            ":TRIG:STAT?", ":WAV:SOUR?", ":WAV:MODE?", ":WAV:FORM?")}
        observation = dict(attempt=attempt+1, first=first, second=second, state=state)
        history.append(observation)
        try:
            fields = second.split(",")
            points = int(fields[2])
            dt = float(fields[4])
            valid = (len(fields) == 10 and int(fields[0]) == 0 and int(fields[1]) == 2
                     and points > 0 and math.isfinite(dt) and dt > 0
                     and all(math.isfinite(float(v)) for v in fields)
                     and math.isclose(dt * float(acquisition[":ACQ:SRAT?"]), 1,
                                      rel_tol=1e-5))
            depth = acquisition[":ACQ:MDEP?"]
            if depth.isdigit():
                valid = valid and points == int(depth)
        except (ValueError, IndexError):
            valid = False
        if state[":TRIG:STAT?"] != "STOP":
            raise RuntimeError("等待RAW参数稳定时示波器已离开STOP；未请求波形数据。")
        if {name: query(name) for name in acquisition} != acquisition:
            raise RuntimeError("等待RAW参数稳定时采样或水平设置已改变；未请求波形数据。")
        if valid and first == second and state == {
                ":TRIG:STAT?": "STOP", ":WAV:SOUR?": f"CHAN{channel}",
                ":WAV:MODE?": "RAW", ":WAV:FORM?": "BYTE"}:
            entry["preamble"] = second
            return points
        observation["rejected"] = True
    raise ValueError(
        f"CH{channel} RAW波形参数3次未稳定或与采样率/存储深度不符，未开始该通道下载；"
        f"最后两次返回：{first!r} / {second!r}。检查记录已保存在metadata.json。")


def prepare_range(send, query, channel, preamble, start, end, entry):
    for attempt in range(1, 4):
        if attempt > 1:
            # Recover only before DATA?, while the ASCII stream is synchronized.
            verify_capture(query, channel, preamble)
            send(":WAV:STAR 1")
        send(f":WAV:STOP {end}")
        send(f":WAV:STAR {start}")
        actual_start = query(":WAV:STAR?")
        actual_end = query(":WAV:STOP?")
        observation = {
            "attempt": attempt, "requested_start": start, "requested_stop": end,
            "observed_start": actual_start, "observed_stop": actual_end,
        }
        if int(actual_start) == start and int(actual_end) == end:
            if attempt > 1:
                entry.setdefault("range_recovery", []).append(observation)
            return
        entry.setdefault("range_recovery", []).append(observation)
    raise ValueError(
        f"CH{channel} 下载范围确认失败（已尝试3次）：请求 {start}–{end}，"
        f"示波器返回 {actual_start}–{actual_end}；"
        f"已保存 {entry.get('downloaded_points', 0)} 点，记录不完整")


def download_channel(send, query, stream, target, channel, points, entry):
    entry["downloaded_points"] = 0
    verify_capture(query, channel, entry["preamble"])
    digest = hashlib.sha256()
    for start in range(1, points + 1, 100000):
        end = min(start + 99999, points)
        entry["pending_range"] = {"start": start, "stop": end}
        prepare_range(send, query, channel, entry["preamble"], start, end, entry)
        send(":WAV:DATA?")
        data = block(stream, 100000)
        if len(data) != end - start + 1:
            raise ValueError(
                f"CH{channel} 数据长度不符：请求 {start}–{end}，收到 {len(data)} 字节；"
                "停止下载，不在可能失步的数据流上重试")
        target.write(data)
        digest.update(data)
        entry["downloaded_points"] = end
        print(f"TRANSFER {channel} {end} {points}", flush=True)
    verify_capture(query, channel, entry["preamble"])
    entry.pop("pending_range", None)
    entry["sha256"] = digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ip", default="169.254.229.90")
    parser.add_argument("--key", type=int, required=True, choices=range(1, 25))
    parser.add_argument("--force", choices=("soft", "medium", "hard"), required=True)
    parser.add_argument("--trial", type=int, required=True)
    parser.add_argument("--instrument", required=True)
    parser.add_argument("--volume", required=True)
    parser.add_argument("--effects", required=True)
    parser.add_argument("--bitstream", help="本次人工选择的烧录文件，不沿用全局版本")
    parser.add_argument("--expected-sha256", help="计划建立时固定的文件哈希")
    parser.add_argument("--joint-analysis", action="store_true",
                        help="同次行列联合采集：保存及频谱后由联合引擎定位 B")
    args = parser.parse_args()
    if args.trial < 1:
        parser.error("--trial must be positive")
    root = Path(__file__).resolve().parents[1]
    base = directory("raw", "latency")
    if args.bitstream:
        from latency_session import describe_version
        version = describe_version(args.bitstream)
    else:
        version = json.loads((base / "current_board_version.json").read_text(encoding="utf-8"))
    bitstream = Path(version["bitstream_path"])
    digest = hashlib.sha256(bitstream.read_bytes()).hexdigest().upper()
    if digest != version["sha256"]:
        raise RuntimeError("Bitstream changed since user confirmation")
    if args.expected_sha256 and digest != args.expected_sha256.upper():
        raise RuntimeError("烧录文件已在计划建立后改变，请结束计划并重新确认版本。")
    from latency_session import image_folder
    output = image_folder(digest, args.instrument, base) / f"K{args.key:02}" / args.force / f"trial_{args.trial:03}"
    if output.exists():
        raise FileExistsError(f"Refusing to overwrite {output}")
    trial = {
        "key": args.key,
        "force_label": args.force,
        "trial": args.trial,
        "instrument_user_reported": args.instrument,
        "volume_user_reported": args.volume,
        "effects_user_reported": args.effects,
        "version": version,
        "capture_time": datetime.now().astimezone().isoformat(),
        "column_index": (args.key - 1) % 6,
        "a_row_index": ((args.key - 1) // 6) * 2,
        "b_row_index": ((args.key - 1) // 6) * 2 + 1,
        "status": "incomplete",
        "b_timing": ("Joint digital rows/column validation follows this scope download"
                     if args.joint_analysis else
                     "Indirect column pulse-width inference, not direct physical closure"),
    }
    metadata = {}
    with socket.create_connection((args.ip, 5555), 10) as sock:
        sock.settimeout(60)
        with sock.makefile("rb") as stream:
            def send(command):
                sock.sendall((command + "\n").encode("ascii"))

            def query(command):
                send(command)
                return stream.readline().decode("ascii").strip()

            state = query(":TRIG:STAT?")
            if state != "STOP":
                raise RuntimeError(f"Scope is {state}; stop manually before saving")
            identity = query("*IDN?")
            if "DS2202A,DS2D192700914" not in identity:
                raise RuntimeError(f"Unexpected instrument: {identity}")
            output.mkdir(parents=True, exist_ok=False)
            save_json(output / "trial.json", trial)
            original = {}
            restore_safe = True
            try:
                metadata["*IDN?"] = identity
                metadata[":TRIG:STAT?"] = state
                for cmd in (":ACQ:MDEP?", ":ACQ:SRAT?", ":TIM:SCAL?", ":TIM:OFFS?"):
                    metadata[cmd] = query(cmd)
                send(":DISPlay:DATA?")
                image = block(stream, 20_000_000)
                if image[:2] != b"BM":
                    raise ValueError("Screenshot is not BMP")
                screen_file(output, "latency", writing=True).write_bytes(image)
                original = {name: query(":WAV:" + name + "?")
                            for name in ("SOUR", "MODE", "FORM", "STAR", "STOP")}
                metadata["original_transfer"] = original
                send(":WAV:MODE RAW")
                send(":WAV:FORM BYTE")
                if query(":WAV:MODE?") != "RAW":
                    raise RuntimeError("RAW transfer rejected")
                for channel in (1, 2):
                    send(f":WAV:SOUR CHAN{channel}")
                    entry = {name: query(f":CHAN{channel}:{name}?")
                             for name in ("SCAL", "OFFS", "PROB", "COUP", "BWL")}
                    metadata[f"CH{channel}"] = entry
                    points = prepare_channel(send, query, channel, entry, metadata)
                    print(f"TRANSFER {channel} 0 {points}", flush=True)
                    with (output / f"ch{channel}.bin").open("xb") as target:
                        download_channel(send, query, stream, target, channel, points, entry)
                    entry["error"] = query(":SYST:ERR?")
                    if not entry["error"].startswith("0,"):
                        raise RuntimeError(entry["error"])
                    if query(":TRIG:STAT?") != "STOP":
                        raise RuntimeError("Acquisition state changed during download")
                    print(f"CH{channel}: {points} points saved", flush=True)
                metadata["final_trigger_state"] = query(":TRIG:STAT?")
                if metadata["final_trigger_state"] != "STOP":
                    raise RuntimeError("Acquisition state changed before completion")
                trial["status"] = "complete"
            except Exception as error:
                trial["error"] = repr(error)
                trial["error_message"] = str(error)
                restore_safe = not isinstance(
                    error, (BinaryTransferError, OSError, EOFError, UnicodeError))
                raise
            finally:
                try:
                    restore_transfer(send, original, metadata, safe=restore_safe)
                finally:
                    save_json(output / "metadata.json", metadata)
                    save_json(output / "trial.json", trial)
    print(f"Saved trial: {output}")
    print("SPECTRUM processing", flush=True)
    try:
        from latency_spectrum import generate
        print(f"Spectrum: {generate(output)}", flush=True)
    except Exception as error:
        save_json(output / "audio_spectrum_error.json", {"error": repr(error)})
        print(f"SPECTRUM_WARNING Raw capture is saved; spectrum generation failed: {error}", flush=True)
    if args.joint_analysis:
        print("示波器原始数据已保存，B 起点交由同次数字行列联合分析。", flush=True)
        return
    print("LATENCY processing", flush=True)
    try:
        from review_latency_evidence import generate as review
        print(f"Latency report: {review(output)}", flush=True)
    except Exception as error:
        save_json(output / "latency_analysis_error.json", {"error": repr(error), "message": str(error)})
        print(f"LATENCY_WARNING Raw capture is saved; timing analysis failed: {error}", flush=True)


if __name__ == "__main__":
    main()

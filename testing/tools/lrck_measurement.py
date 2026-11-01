"""STOP-only LRCK evidence capture and offline edge-based frequency analysis."""

import csv
from datetime import datetime
import hashlib
import html
import json
from pathlib import Path
import socket

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

from capture_key_trial import block
from polyphony_acceptance.report_chinese import configure_plot, metadata_rows
from measurement_files import report_folder, screen_file, relative_link


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")


def decode(data, entry):
    p = np.asarray([float(v) for v in entry["preamble"].split(",")])
    if (len(p) != 10 or not np.all(np.isfinite(p)) or p[0] != 0 or p[1] != 2
            or p[4] <= 0 or p[7] <= 0 or p[2] != len(data)):
        raise ValueError("无效的 RAW BYTE 波形头或数据长度")
    if hashlib.sha256(data).hexdigest().lower() != entry["sha256"].lower():
        raise ValueError("原始数据 SHA256 不匹配")
    raw = np.frombuffer(data, dtype=np.uint8)
    return raw, (raw.astype(float) - p[8] - p[9]) * p[7], p


def analyze_edges(voltage, dt):
    y = np.asarray(voltage, dtype=float)
    if (y.ndim != 1 or y.size < 100 or not np.isfinite(dt) or dt <= 0
            or not np.all(np.isfinite(y))):
        raise ValueError("无效的 LRCK 波形")
    low, high = np.percentile(y, [10, 90])
    swing = high - low
    if swing < .5:
        raise ValueError("数字电平幅度不足 0.5 V；请检查 LCK 接线、倍率和量程")
    midpoint = (low + high) / 2
    candidates = np.flatnonzero((y[:-1] < midpoint) & (y[1:] >= midpoint))
    # Accept a rise only after the signal has returned to the lower hysteresis band.
    lows = np.flatnonzero(y < low + .3 * swing)
    rises = []
    previous = -1
    for i in candidates:
        k = np.searchsorted(lows, i, side="right") - 1
        if k < 0 or lows[k] <= previous:
            continue
        stop = np.searchsorted(lows, i + 1)
        end = lows[stop] if stop < len(lows) else len(y)
        if np.max(y[i + 1:end], initial=low) < low + .7 * swing:
            continue
        rises.append((i + (midpoint - y[i]) / (y[i + 1] - y[i])) * dt)
        previous = i
    times = np.asarray(rises)
    if len(times) < 21:
        raise ValueError("不足 20 个完整 LRCK 周期；请增大记录跨度并确认接线")
    periods = np.diff(times)
    median = float(np.median(periods))
    frequency = float((len(times) - 1) / (times[-1] - times[0]))
    if not 8000 <= frequency <= 384000:
        raise ValueError(f"测得 {frequency:.1f} Hz，不在本工具的音频 LRCK 范围内；确认没有接 BCK")
    if median / dt < 20:
        raise ValueError("每周期不足 20 个采样点，请提高示波器采样率后重新采集")
    if np.max(np.abs(periods - median)) > .1 * median:
        raise ValueError("周期变化超过 10%，可能有毛刺、漏边沿或不连续时钟，不能作为采样率证据")
    return {
        "measured_lrck_hz": frequency,
        "mean_period_us": float(np.mean(periods) * 1e6),
        "min_period_us": float(periods.min() * 1e6),
        "max_period_us": float(periods.max() * 1e6),
        "period_std_ns_observed": float(periods.std() * 1e9),
        "complete_periods": len(periods), "samples_per_period": median / dt,
        "level_low_v": float(low), "level_high_v": float(high),
        "threshold_v": float(midpoint), "sample_interval_ns": dt * 1e9,
        "relative_to_nominal_48000_ppm": (frequency / 48000 - 1) * 1e6,
        "method": "筛选有效上升沿，线性插值定位阈值，使用全部完整周期",
    }, times


def generate(folder):
    configure_plot()
    folder = Path(folder)
    output = report_folder(folder, "lrck")
    output.mkdir(parents=True, exist_ok=True)
    meta = json.loads((folder / "capture.json").read_text(encoding="utf-8"))
    if meta.get("status") != "complete" or meta.get("kind") != "lrck":
        raise ValueError("不是完整的 LRCK 记录")
    raw, y, p = decode((folder / "raw.bin").read_bytes(), meta["waveform"])
    if np.any((raw <= 1) | (raw >= 254)):
        raise ValueError("LRCK 波形触及 ADC 上下限，请调整量程/偏移后重测")
    result, times = analyze_edges(y, float(p[4]))
    result.update({
        "kind": "lrck_analysis", "raw_sha256": meta["waveform"]["sha256"],
        "scope_identity": meta["scope_identity"], "scope_sample_rate_hz": 1 / p[4],
        "firmware_user_reported": meta["firmware_user_reported"],
        "bitstream_sha256_user_file": meta.get("bitstream_sha256_user_file"),
        "wiring_user_confirmed": meta["wiring_user_confirmed"],
        "source_capture_sha256": hashlib.sha256((folder / "capture.json").read_bytes()).hexdigest(),
        "cautions": [
            "LRCK 结果依赖正确连接 DAC 的 LCK/WS 输入，不能接 BCK 或模拟 L。",
            "示波器采集采样率不是 DAC 音频输出采样率。",
            "观测周期变化包含示波器量化和时基误差，不证明无抖动。",
            "固件身份和物理接线为人工声明，并非自动核实。",
        ],
    })
    if not meta["wiring_user_confirmed"]:
        raise ValueError("尚未确认信号来自 DAC LCK")
    write_json(output / "analysis.json", result)
    with (output / "periods.csv").open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(("上升沿相对触发时间（s）", "周期（µs）"))
        origin = p[5] - p[6] * p[4]
        writer.writerows(zip(times[:-1] + origin, np.diff(times) * 1e6))
    fig, ax = plt.subplots(figsize=(10, 4), layout="constrained")
    start = max(0, int(times[0] / p[4]) - 10)
    end = min(len(y), int(times[0] / p[4] + 6 / result["measured_lrck_hz"] / p[4]))
    indices = np.arange(start, end)
    ax.plot((indices * p[4] - times[0]) * 1e6, y[start:end], color="#17675c", lw=1)
    ax.axhline(result["threshold_v"], color="#ac303d", ls=":", label="边沿判定阈值")
    ax.set(xlabel="相对首个有效上升沿的时间（µs）", ylabel="电压（V）",
           title=f"LRCK 实测 {result['measured_lrck_hz']:.3f} Hz | "
                 f"{result['complete_periods']} 个完整周期")
    ax.grid(alpha=.2)
    ax.legend()
    fig.savefig(output / "lrck_waveform.png", dpi=150)
    plt.close(fig)
    rows = metadata_rows(result, exclude=("cautions",))
    (output / "report.html").write_text(
        '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>LRCK 采样率实测</title>'
        '<style>body{font:16px sans-serif;max-width:1100px;margin:32px auto;padding:16px}'
        'td,th{border:1px solid #ccc;padding:8px;text-align:left;overflow-wrap:anywhere}'
        'table{border-collapse:collapse;width:100%}img{max-width:100%}</style>'
        '<h1>LRCK 采样率实测</h1>'
        f'<p>实测：{result["measured_lrck_hz"]:.3f} Hz。不是示波器采集采样率。</p>'
        '<p>接线与固件版本为人工确认；周期离散包含仪器误差，不证明无抖动，不代表比赛验收通过。</p>'
        '<img src="lrck_waveform.png" alt="LRCK 原始数据波形">'
        f'<p><a href="{html.escape(relative_link(screen_file(folder, "lrck"), output))}">示波器原始屏幕</a> · <a href="periods.csv">逐周期数据</a></p>'
        f'<table>{rows}</table>', encoding="utf-8")
    return output / "report.html"


def capture(ip, channel, folder, firmware, progress, wiring_confirmed):
    """Only transfer settings are written; acquisition/timebase/trigger stay untouched."""
    if channel not in (1, 2) or not firmware.strip() or not wiring_confirmed:
        raise ValueError("必须选择通道、填写固件记录并确认 LCK 接线")
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=False)
    meta = dict(kind="lrck", status="incomplete", channel=channel,
                firmware_user_reported=firmware.strip(), wiring_user_confirmed=True,
                captured_at=datetime.now().astimezone().isoformat())
    try:
        firmware_file = Path(firmware)
        if firmware_file.is_file():
            meta["bitstream_sha256_user_file"] = hashlib.sha256(firmware_file.read_bytes()).hexdigest()
        with socket.create_connection((ip.strip(), 5555), 5) as sock:
            sock.settimeout(60)
            with sock.makefile("rb") as stream:
                def send(command):
                    sock.sendall((command + "\n").encode("ascii"))

                def query(command):
                    send(command)
                    return stream.readline(4096).decode("ascii").strip()

                identity = query("*IDN?")
                if "DS2202A" not in identity or "RIGOL" not in identity.upper():
                    raise ValueError("仅支持 RIGOL DS2202A")
                if query(":TRIG:STAT?") != "STOP":
                    raise ValueError("请先手动停止示波器")
                if query(":ACQ:TYPE?").upper() not in ("NORM", "NORMAL"):
                    raise ValueError("请使用 Normal 采集模式")
                if query(f":CHAN{channel}:DISP?").upper() not in ("1", "ON"):
                    raise ValueError("所选通道未开启")
                meta["scope_identity"] = identity
                meta["settings"] = {key: query(key) for key in (
                    ":ACQ:SRAT?", ":TIM:SCAL?", ":TIM:OFFS?",
                    f":CHAN{channel}:SCAL?", f":CHAN{channel}:OFFS?",
                    f":CHAN{channel}:COUP?", f":CHAN{channel}:PROB?")}
                send(":DISPlay:DATA?")
                screen = block(stream, 20_000_000)
                if screen[:2] != b"BM":
                    raise ValueError("屏幕截图不是 BMP")
                screen_file(folder, "lrck", writing=True).write_bytes(screen)
                original = {name: query(":WAV:" + name + "?")
                            for name in ("SOUR", "MODE", "FORM", "STAR", "STOP")}
                try:
                    send(":WAV:MODE RAW")
                    send(":WAV:FORM BYTE")
                    send(f":WAV:SOUR CHAN{channel}")
                    if query(":WAV:MODE?") != "RAW" or query(":WAV:FORM?") != "BYTE":
                        raise ValueError("RAW BYTE 设置未生效")
                    preamble = query(":WAV:PRE?")
                    points = int(preamble.split(",")[2])
                    if not 1 <= points <= 56_000_000:
                        raise ValueError("无原始采样点或超过本工具支持的记录深度")
                    progress(0, points)
                    digest = hashlib.sha256()
                    with (folder / "raw.bin").open("xb") as f:
                        for start in range(1, points + 1, 100000):
                            end = min(start + 99999, points)
                            send(f":WAV:STOP {end}")
                            send(f":WAV:STAR {start}")
                            if (int(query(":WAV:STAR?")) != start
                                    or int(query(":WAV:STOP?")) != end):
                                raise ValueError("示波器截断了下载范围")
                            send(":WAV:DATA?")
                            data = block(stream, 100000)
                            if len(data) != end - start + 1:
                                raise ValueError("原始数据分块长度错误")
                            f.write(data)
                            digest.update(data)
                            progress(end, points)
                    meta["waveform"] = dict(preamble=preamble, sha256=digest.hexdigest())
                    if query(":TRIG:STAT?") != "STOP":
                        raise ValueError("下载过程中采集状态发生变化")
                    error = query(":SYST:ERR?")
                    if not error.startswith("0,"):
                        raise ValueError(error)
                    meta["status"] = "complete"
                finally:
                    send(":WAV:STAR 1")
                    for name in ("SOUR", "MODE", "FORM", "STOP", "STAR"):
                        send(f":WAV:{name} {original[name]}")
    except Exception as error:
        meta["status"] = "incomplete"
        meta["error"] = str(error)
        raise
    finally:
        write_json(folder / "capture.json", meta)
    return generate(folder)

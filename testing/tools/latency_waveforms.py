"""Verified raw scope loading and onset analysis, independent of B inference."""

import hashlib
import json
import math
from pathlib import Path

import numpy as np
from scipy.signal import resample_poly

from latency_session import version_correction


def confirmation_description(row):
    rate = row["rate_Hz"]
    count = row.get("confirmation_samples", math.ceil(.0001/(1/rate)))
    span = row.get("confirmation_first_last_span_us", (count-1)/rate*1e6)
    return (f"离散采样点确认：{count}点连续超阈值，首末跨度{span:.1f} µs"
            "（名义确认窗100 µs；未验证点间持续超阈值）")


def load(trial):
    trial = Path(trial)
    record = json.loads((trial / "trial.json").read_text(encoding="utf-8"))
    if record.get("status") != "complete":
        raise ValueError("示波器记录未完整保存。")
    meta = json.loads((trial / "metadata.json").read_text(encoding="utf-8"))
    channels, preambles, hashes, rails = [], [], {}, []
    for channel in ("CH1", "CH2"):
        p = list(map(float, meta[channel]["preamble"].split(",")))
        if (len(p) != 10 or not np.isfinite(p).all() or p[0] != 0 or p[1] != 2
                or p[4] <= 0 or p[7] <= 0):
            raise ValueError("原始 BYTE 波形缩放参数无效。")
        raw = np.fromfile(trial / f"ch{channel[-1]}.bin", dtype=np.uint8)
        digest = hashlib.sha256(raw.tobytes()).hexdigest()
        if digest != meta[channel]["sha256"].lower() or len(raw) != p[2]:
            raise ValueError(f"{channel} 原始数据哈希或长度与采集记录不一致。")
        channels.append((raw.astype(float)-p[8]-p[9])*p[7])
        preambles.append(p)
        hashes[channel] = digest
        rails.append([int((raw <= 1).sum()), int((raw >= 254).sum())])
    if preambles[0][2] != preambles[1][2] or preambles[0][4:7] != preambles[1][4:7]:
        raise ValueError("两路原始数据时间轴不一致。")
    correction = version_correction(trial)
    return channels, preambles[0][4], dict(
        kind="joint_audio_onsets", raw_sha256=hashes, raw_hashes_verified=True,
        rails=rails, version_user_recorded=(
            correction["corrected_version"] if correction else record.get("version", {})),
        version_correction=correction,
    )


def onsets(ch2, dt, first_contact):
    """Search after the first observed column contact, not a guessed B instant."""
    rows = []
    for mode in ("polyphase", "block_mean"):
        for rate in (25000, 50000, 100000):
            factor = max(1, round(1/(rate*dt)))
            if mode == "polyphase":
                y = resample_poly(ch2, 1, factor)
                t = np.arange(len(y))*factor*dt
            else:
                y = ch2[:len(ch2)//factor*factor].reshape(-1, factor).mean(axis=1)
                t = (np.arange(len(y))*factor+(factor-1)/2)*dt
            baseline = y[(t > first_contact-.0035) & (t < first_contact-.0005)]
            if len(baseline) < 10:
                raise ValueError("按下前基线不足，请保留至少 0.5 ms 可用静音基线。")
            center = float(np.median(baseline))
            length = int(np.ceil(.0001/(factor*dt)))
            for threshold in (.010, .015, .020):
                above = (abs(y-center) > threshold) & (t > first_contact)
                hits = np.flatnonzero(np.convolve(
                    above.astype(int), np.ones(length, int), "valid") >= length)
                if not len(hits):
                    raise ValueError("未找到满足名义0.1 ms离散点确认规则的模拟起音。")
                rows.append(dict(
                    method=mode, rate_Hz=1/(factor*dt), threshold_mV=threshold*1000,
                    confirmation_rule="consecutive_sample_points_abs_threshold_v1",
                    confirmation_samples=length, nominal_confirmation_us=100.,
                    confirmation_first_last_span_us=(length-1)*factor*dt*1e6,
                    continuous_between_samples_verified=False,
                    onset_scope_s=float(t[hits[0]]),
                    onset_from_contact_ms=float((t[hits[0]]-first_contact)*1000),
                    baseline_std_mV=float(np.std(baseline)*1000),
                ))
    return rows

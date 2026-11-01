"""Offline onset evidence and conditional timing envelopes for saved trials."""

import json
import hashlib
import argparse
import html
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy.signal import resample_poly
from scope_column_pulses import extract
from polyphony_acceptance.report_chinese import configure_plot, display_value
from polyphony_acceptance.acceptance_reports import page
from latency_session import version_correction
from measurement_files import report_folder, screen_file, relative_link


ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "measurements/full_key_latency/image_F15A77D2B275"
plt.rcParams.update({"font.size": 10,
                     "svg.fonttype": "none", "axes.spines.top": False,
                     "axes.spines.right": False})


def save(fig, folder, name):
    fig.savefig(folder / f"{name}.png", dpi=160)
    fig.savefig(folder / f"{name}.svg")
    plt.close(fig)


def mark_latency(ax, delay, y=.82):
    """Place timing marks in data-x/axes-y coordinates, clear of the trace."""
    transform = ax.get_xaxis_transform()
    for x, color in ((0, "#b0283c"), (delay, "#087f8c")):
        ax.axvline(x, color=color, ls="--", lw=1)
    ax.annotate("", xy=(0, y), xytext=(delay, y),
                xycoords=transform, textcoords=transform,
                arrowprops=dict(arrowstyle="<->", color="#202b30", lw=1.4))
    ax.text(delay/2, y+.045, f"B 参考 → 模拟起音：{delay:.5f} ms",
            transform=transform, ha="center", va="bottom", weight="bold", fontsize=11,
            bbox=dict(facecolor="white", edgecolor="none", alpha=.9, pad=3))
    ax.text(0, y-.08, "起点：推断 B\n0 ms（非直接物理闭合）",
            transform=transform, ha="left", va="top", color="#b0283c", fontsize=9,
            bbox=dict(facecolor="white", edgecolor="none", alpha=.9, pad=2))
    ax.text(delay, y-.08, f"终点：模拟起音\n{delay:.5f} ms",
            transform=transform, ha="right", va="top", color="#087f8c", fontsize=9,
            bbox=dict(facecolor="white", edgecolor="none", alpha=.9, pad=2))


def raw_envelope(ax, values, dt, left, right, reference, scale, baseline=0):
    i0, i1 = max(0, int(left/dt)), min(len(values), int(right/dt)+1)
    # The display includes every sample, including the final incomplete bin.
    stride = max(1, (i1-i0)//2200)
    indices = np.arange(i0, i1, stride)
    x = (indices*dt-reference)*scale
    low = np.minimum.reduceat(values[i0:i1], indices-i0)-baseline
    high = np.maximum.reduceat(values[i0:i1], indices-i0)-baseline
    ax.fill_between(x, low, high, color="#87969d", alpha=.4,
                    label="CH2 原始样本范围（已扣基线）")


def timing_figures(out, title, ch1, ch2, dt, starts, stops, timing,
                   t, y, onset, baseline):
    inferred = timing["inferred"]
    delay = (onset-inferred)*1000
    j = timing["j"]
    widths = (stops-starts)*dt
    fig, (ruler, ax) = plt.subplots(
        2, 1, figsize=(14, 7), height_ratios=(1.3, 3), layout="constrained")
    fig.suptitle(title+" | B 参考定位与延迟计时", fontsize=13)
    ruler.set(xlim=(-.15, delay+.35), ylim=(0, 1), yticks=[],
              xlabel="相对推断 B 参考的时间（ms）")
    ruler.spines["left"].set_visible(False)
    mark_latency(ruler, delay, .8)
    ruler.text(.5, .12, "计时标尺：两端来自同一次记录；下方放大起点附近的 CH1",
               transform=ruler.transAxes, ha="center", color="#50616b", fontsize=9)
    lo, hi = starts[max(0, j-2)]*dt-15e-6, stops[j+1]*dt+30e-6
    indices = np.arange(max(0, int(lo/dt)), min(len(ch1), int(hi/dt)))
    stride = max(1, len(indices)//3500)
    groups = indices[:len(indices)//stride*stride].reshape(-1, stride)
    tx = ((groups[:, 0]+groups[:, -1])/2*dt-inferred)*1e6
    ax.fill_between(tx, ch1[groups].min(axis=1), ch1[groups].max(axis=1),
                    color="#b08000", alpha=.65, label="CH1 原始数据最小/最大包络")
    ax.plot(tx, ch1[groups].mean(axis=1), color="#866000", lw=.6)
    ax.axvspan((timing["physical_lo"]-inferred)*1e6,
               (timing["physical_hi"]-inferred)*1e6,
               color="#888888", alpha=.15, label="条件性物理闭合窗口")
    ax.axvline(0, color="#b0283c", ls="--", label="计时起点：推断 B 参考")
    for k in (j-1, j, j+1):
        ax.text(((starts[k]+stops[k])/2*dt-inferred)*1e6, 1.8,
                f"{widths[k]*1e6:.2f} µs", ha="center", fontsize=9)
    if timing["partial"]:
        ax.axvspan(0, timing["partial"]["width_us"], color="#087f8c", alpha=.15,
                   label="首个 B 部分脉冲（计入起点）")
    ax.set(xlabel="相对推断 B 参考的时间（µs）", ylabel="CH1 电压（V）",
           title="起点局部放大：相邻扫描行的脉宽变化", ylim=(-.5, 3.8))
    ax.grid(alpha=.18)
    ax.legend(loc="upper left", bbox_to_anchor=(0, -.22), ncol=2, fontsize=9)
    save(fig, out, "b_detail")

    fig, (overview, detail) = plt.subplots(
        2, 1, figsize=(14, 8), height_ratios=(1.2, 1), layout="constrained")
    fig.suptitle(title+" | B 参考到 DAC 模拟起音", fontsize=13)
    for ax, left, right in (
            (overview, inferred-.00015, onset+.001),
            (detail, onset-.0008, onset+.001)):
        raw_envelope(ax, ch2, dt, left, right, inferred, 1000, baseline)
        mask = (t > left) & (t < right)
        ax.plot((t[mask]-inferred)*1000, y[mask], color="#087f8c", lw=1,
                label="50 kSa/s FIR 波形（已扣基线）")
        ax.axhline(.015, color="#b0283c", ls=":", label="正负 15 mV 阈值")
        ax.axhline(-.015, color="#b0283c", ls=":")
        ax.set(xlim=((left-inferred)*1000, (right-inferred)*1000),
               xlabel="相对推断 B 参考的时间（ms）", ylabel="CH2 电压（V）")
        ax.grid(alpha=.18)
        ax.legend(loc="upper left", bbox_to_anchor=(0, -.22), ncol=3, fontsize=9)
    bottom, top = overview.get_ylim()
    overview.set_ylim(bottom, top+(top-bottom)*1.1)
    mark_latency(overview, delay)
    overview.set_title("完整计时间隔：起点与终点同时显示")
    detail.axvline(delay, color="#087f8c", ls="--")
    detail.text(.98, .96, f"起音终点 = {delay:.5f} ms\n±15 mV离散点确认（名义100 µs）",
                transform=detail.transAxes, ha="right", va="top", fontsize=9,
                bbox=dict(facecolor="white", edgecolor="#dce3e8", alpha=.95, pad=5))
    detail.set_title("终点局部放大：模拟起音阈值与原始噪声")
    save(fig, out, "audio_detail")


def scan_timing(starts, stops, dt):
    """Fit A phase, admitting one independently checked B-window fragment."""
    starts, stops = np.asarray(starts), np.asarray(stops)
    widths = (stops - starts) * dt
    if len(starts) < 18:
        raise ValueError("有效扫描脉冲不足；需完整记录 A 闭合到 B 闭合的过程")
    # A fast press can reach B before 15 scan frames. Use a shorter seed,
    # then retain the phase, width and consecutive-frame checks below.
    single = float(np.median(widths[:5]))
    doubled = np.flatnonzero(widths > 1.5 * single)
    if not len(doubled):
        if 40e-6 <= single <= 65e-6:
            initial_single = (widths >= 18e-6) & (widths <= 33e-6)
            non_single = np.flatnonzero(~initial_single)
            count = int(non_single[0]) if len(non_single) else len(widths)
            if 0 < count < 5:
                raise ValueError(
                    f"初始单触点脉冲仅 {count} 个，至少需要 5 个稳定脉冲以推断扫描相位；"
                    "后续脉冲已接近双触点宽度，不能仅靠当前列脉宽模型可靠定位 B 起点")
            raise ValueError(
                f"记录首段脉宽中位数约 {single*1e6:.2f} μs，已接近双触点宽度；"
                "未观察到可识别的单触点阶段，无法从列波形定位 B 首次导通。"
                "可能 A/B 间隔过短，或 A 阶段未被观测；不能据此判定接线错误或延迟超标")
        raise ValueError("未找到脉宽变宽，无法推断 B；请检查接线和记录窗口")
    j = int(doubled[0])
    if j < 5:
        raise ValueError(f"初始单触点脉冲仅 {j} 个，至少需要 5 个稳定脉冲以推断扫描相位；"
                         "不能仅靠列脉宽推断 B 起点")
    if j + 3 > len(starts):
        raise ValueError("首次变宽后完整双触点脉冲不足三个，需保留完整按下后记录")
    single = float(np.median(widths[:j]))
    period = float(np.median(np.diff(starts)) * dt)
    if not 180e-6 <= period <= 220e-6:
        raise ValueError("扫描帧周期不在本项目约 200 us 范围，需核实实际 RTL 后更新分析模型")
    if not 18e-6 <= single <= 33e-6:
        raise ValueError("单触点脉宽不符合本项目行扫描模型，不能可靠推断 B")
    double = float(np.median(widths[doubled[:20]]))
    if not 1.7 <= double / single <= 2.3:
        raise ValueError("双触点脉宽不符合相邻 A/B 行模型")
    allowance = 2e-6
    # Establish phase from the single-contact prefix, never from an outlier.
    reference = starts[1] * dt
    cycles = np.rint((starts * dt - reference) / period).astype(int)
    phase = starts * dt - (reference + cycles * period)
    off_grid = np.flatnonzero(abs(phase[1:]) > allowance) + 1
    if len(off_grid) > 1:
        raise ValueError("存在多个非扫描相位脉冲，不能按单个 B 部分脉冲解释")
    keep = np.ones(len(starts), dtype=bool)
    keep[0] = False
    keep[off_grid] = False
    selected_cycles = cycles[keep]
    if np.any(np.diff(selected_cycles) != 1):
        raise ValueError("A 行扫描存在缺帧或重复脉冲，不能建立连续扫描相位")
    fit_period, origin = np.polyfit(selected_cycles, starts[keep] * dt, 1)
    residual = starts[keep] * dt - (origin + selected_cycles * fit_period)
    if max(abs(residual)) > allowance:
        raise ValueError("Scan-phase residual exceeds conditional allowance")
    if not 180e-6 <= fit_period <= 220e-6:
        raise ValueError("拟合扫描周期不符合八行扫描模型")
    row = fit_period / 8
    main = np.flatnonzero(keep)
    before = main[main < j]
    after = main[main >= j]
    if (np.any(abs(widths[before] - single) > allowance)
            or np.any(abs(widths[after] - double) > allowance)
            or np.any(abs(widths[j:j+3] - double) > allowance)):
        raise ValueError("单/双触点脉宽未持续稳定，需复核抖动或其他按键干扰")
    b_start = origin + cycles[j] * fit_period + row
    inferred = starts[j] * dt + double - single
    physical_lo = b_start - fit_period - allowance
    physical_hi = b_start + row + allowance
    partial = None
    if len(off_grid):
        k = int(off_grid[0])
        slot = origin + cycles[k] * fit_period + row
        start, end = starts[k] * dt, stops[k] * dt
        expected_end = origin + cycles[k] * fit_period + double
        if (k != j - 1 or cycles[k] != cycles[j] - 1 or k < 2
                or starts[k-1] * dt >= slot
                or not slot - allowance <= start <= slot + row + allowance
                or abs(end - expected_end) > allowance
                or not 0 < widths[k] <= row + allowance):
            raise ValueError("非相位脉冲不符合 B 窗口内的单个部分脉冲，不能忽略")
        partial = dict(pulse_index=k, start_from_A_ms=(start-starts[0]*dt)*1000,
                       width_us=float(widths[k]*1e6),
                       b_slot_start_from_A_ms=float((slot-starts[0]*dt)*1000),
                       end_fit_error_us=float((end-expected_end)*1e6),
                       interpretation="符合 B 扫描中途导通的部分脉冲模型，非直接物理闭合测量")
        # Include the earlier observation; never silently discard it and time
        # from the next full B slot, which would underestimate latency.
        inferred = start
        physical_lo = slot - fit_period - allowance
        physical_hi = start + allowance
    return dict(j=j, single=single, double=double, inferred=float(inferred),
                b_start=float(b_start), physical_lo=float(physical_lo),
                physical_hi=float(physical_hi), fit_period=float(fit_period),
                residual_us=float(max(abs(residual))*1e6),
                partial=partial, allowance=allowance)


def main(base=BASE, trial=None, output=None):
    configure_plot()
    base = Path(base)
    results = []
    for folder in ([Path(trial)] if trial else sorted(base.glob("K*/*/trial_*"))):
        if not (folder / "ch2.bin").exists():
            raise ValueError(f"Missing raw CH2: {folder}")
        record = json.loads((folder / "trial.json").read_text(encoding="utf-8"))
        correction = version_correction(folder)
        version = correction["corrected_version"] if correction else record.get("version", {})
        if record.get("status") != "complete":
            raise ValueError(f"Incomplete capture: {folder}")
        out = Path(output) if output is not None else report_folder(folder, "latency") / "evidence"
        out.mkdir(parents=True, exist_ok=True)
        meta = json.loads((folder / "metadata.json").read_text(encoding="utf-8"))
        channels = []
        rails = []
        for c in (1, 2):
            p = list(map(float, meta[f"CH{c}"]["preamble"].split(",")))
            if (len(p) != 10 or not np.all(np.isfinite(p)) or p[0] != 0 or p[1] != 2
                    or p[4] <= 0 or p[7] <= 0):
                raise ValueError("Invalid RAW BYTE preamble")
            raw = np.fromfile(folder / f"ch{c}.bin", dtype=np.uint8)
            if hashlib.sha256(raw.tobytes()).hexdigest().lower() != meta[f"CH{c}"]["sha256"].lower():
                raise ValueError(f"Raw data hash mismatch: {folder}, CH{c}")
            if len(raw) != int(p[2]):
                raise ValueError("Raw data length differs from preamble")
            channels.append((raw.astype(float) - p[8] - p[9]) * p[7])
            rails.append([int((raw <= 1).sum()), int((raw >= 254).sum())])
        p1 = list(map(float, meta["CH1"]["preamble"].split(",")))
        if p1[4:7] != p[4:7]:
            raise ValueError("Channel timebases differ")
        dt = p1[4]
        ch1, ch2 = channels
        starts, stops, censored = extract(ch1, dt)
        timing = scan_timing(starts, stops, dt)
        widths = (stops - starts) * dt
        a = starts[0] * dt
        j, single = timing["j"], timing["single"]
        inferred = timing["inferred"]
        physical_lo, physical_hi = timing["physical_lo"], timing["physical_hi"]
        sensitivities = []
        primary = None
        for mode, rates in (("polyphase", (25000, 50000, 100000)),
                            ("block_mean", (25000, 50000, 100000))):
            for rate in rates:
                factor = round(1 / (rate * dt))
                if mode == "polyphase":
                    y = resample_poly(ch2, 1, factor)
                    t = np.arange(len(y)) * factor * dt
                else:
                    y = ch2[:len(ch2)//factor*factor].reshape(-1, factor).mean(axis=1)
                    t = (np.arange(len(y)) * factor + (factor-1)/2) * dt
                baseline = y[(t > a-.0035) & (t < a-.0005)]
                if len(baseline) < 10:
                    raise ValueError("按下前基线不足，请保留至少 0.5 ms 可用静音基线")
                center = float(np.median(baseline))
                length = int(np.ceil(.0001 / (factor * dt)))
                for threshold in (.010, .015, .020):
                    above = (abs(y-center) > threshold) & (t > inferred)
                    hits = np.flatnonzero(np.convolve(
                        above.astype(int), np.ones(length, int), "valid") >= length)
                    if not len(hits):
                        raise ValueError("No sustained onset")
                    onset = float(t[hits[0]])
                    if stops[-1]*dt <= onset+.0001:
                        raise ValueError("完整扫描证据未覆盖起音及 0.1 ms 确认区间")
                    sensitivities.append({
                        "method": mode, "rate_Hz": 1/(factor*dt),
                        "threshold_mV": threshold*1000,
                        "onset_from_A_ms": (onset-a)*1000,
                        "latency_from_inferred_B_ms": (onset-inferred)*1000,
                        "conditional_latest_delay_ms": (onset-physical_lo)*1000,
                        "baseline_std_mV": float(np.std(baseline)*1000),
                    })
                    if mode == "polyphase" and rate == 50000 and threshold == .015:
                        primary = (t, y-center, onset)
                        primary_baseline = center
        t, y, onset = primary
        force = {"soft":"轻", "medium":"中", "hard":"重"}.get(record.get("force_label"), "未记录")
        title = f"K{record['key']} / {force}力度 / 第 {record['trial']} 次"
        timing_figures(out, title, ch1, ch2, dt, starts, stops, timing,
                       t, y, onset, primary_baseline)
        values=[v["latency_from_inferred_B_ms"] for v in sensitivities]
        upper=max(v["conditional_latest_delay_ms"] for v in sensitivities)
        result={
            "trial":title,"rails":rails,
            "kind":"latency_evidence",
            "raw_sha256":{f"CH{c}":meta[f"CH{c}"]["sha256"] for c in (1,2)},
            "version_user_recorded":version,
            "version_correction":correction,
            "primary_latency_from_inferred_B_ms":float((onset-inferred)*1000),
            "raw_hashes_verified":True,
            "single_width_us":single*1e6,
            "first_widened_width_us":float(widths[j]*1e6),
            "analysis_model_version":"partial_b_v2",
            "terminal_censored_pulse":censored,
            "minimum_retained_pulse_us":1,
            "partial_B_pulse":timing["partial"],
            "B_reference_kind":("partial_pulse_threshold_crossing" if timing["partial"]
                                else "full_pulse_width_inference"),
            "scan_period_us":float(timing["fit_period"]*1e6),
            "phase_fit_max_residual_us":timing["residual_us"],
            "inferred_B_from_A_ms":float((inferred-a)*1000),
            "conditional_physical_closure_interval_relative_B_us":
                [(physical_lo-inferred)*1e6,(physical_hi-inferred)*1e6],
            "phase_allowance_us":timing["allowance"]*1e6,
            "method_sensitivity_latency_ms":[min(values),max(values)],
            "conditional_sensitivity_envelope_upper_ms":upper,
            "remaining_to_5ms_ms":5-upper,
            "strict_metrological_upper_bound":False,
            "cautions":[
                "B 由相邻扫描行的脉宽变宽间接推断，不是直接观测物理闭合。",
                "条件性闭合窗口依赖触点稳定闭合和固定八行扫描模型。",
                "部分脉冲需符合 B 窗口及后续连续稳定条件；符合模型不等于直接证明触点闭合。",
                "2 µs 相位余量为分析模型假定，不是已校准的全系统误差预算。",
                "填补约 0.55 µs 毛刺；保留首个长扫描脉冲之后超过 1 µs 的低脉冲，更短导通不在本模型证明范围。",
                "零相位 FIR 与阈值会影响模拟起音判定。",
                "接近量程极限的样本和基线噪声需要复核；这不是比赛验收。",
                "单次记录不证明全键、最坏延迟或无抖动。"],
            "sensitivities":sensitivities}
        (out/"review.json").write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding="utf-8")
        rows = "".join(
            f"<tr><td>{html.escape(display_value('method', v['method']))}</td><td>{v['rate_Hz']:.0f}</td>"
            f"<td>{v['threshold_mV']:.0f}</td><td>{v['latency_from_inferred_B_ms']:.5f}</td>"
            f"<td>{v['conditional_latest_delay_ms']:.5f}</td></tr>" for v in sensitivities)
        version_text = (
            f"<p>烧录文件（人工记录，未读回 FPGA）：{html.escape(version.get('bitstream_path', '未记录'))}<br>"
            f"SHA256：{html.escape(version.get('sha256', '未记录'))}</p>")
        if correction:
            version_text += (
                '<p><strong>版本更正：本记录原目录及 trial.json 沿用了旧版本标签，不能计入旧版本结果。</strong>'
                f"{html.escape(correction['reason'])} "
                f'<a href="{html.escape(relative_link(folder / "version_correction.json", out))}">查看版本更正记录</a>。原始数据未改动。</p>')
        from latency_budget_report import lookup, section
        budget_section = section(lookup(folder), out, scope_only=True)
        body = (
            '<p class="meta">来源：示波器 CH1 列信号与 CH2 DAC 模拟输出的原始 BYTE 数据。'
            '以下图像为原始数据计算图，不是示波器屏幕截图。</p>'
            '<h2>测量结果</h2><table><thead><tr><th>项目</th><th>结果</th></tr></thead><tbody>'
            '<tr><td>计时起点</td><td>推断 B 参考，图中记为 0 ms（非直接物理闭合）</td></tr>'
            f'<tr><td>计时终点</td><td>模拟起音，图中记为 {(onset-inferred)*1000:.5f} ms</td></tr>'
            f'<tr><td>推断 B → 模拟起音</td><td><strong>{(onset-inferred)*1000:.5f} ms</strong></td></tr>'
            '<tr><td>起音判据</td><td>50 kSa/s 零相位 FIR、正负15 mV、'
            '名义100 µs离散点确认；通常5点跨80 µs，未验证点间持续超阈值。'
            '不是连续时间起音保证，也不能据相位敏感性直接认定硬件抖动。</td></tr>'
            f'<tr><td>方法敏感性范围</td><td>{min(values):.5f}～{max(values):.5f} ms</td></tr>'
            f'<tr><td>条件性扫描窗口及方法敏感性包络最大值</td><td>{upper:.5f} ms（非严格最坏上界）</td></tr>'
            '</tbody></table><h2>固件与记录</h2>'
            + version_text +
            '<h2>判定条件与限制</h2>'
            f'<p>方法敏感性范围：{min(values):.5f}～{max(values):.5f} ms；'
            f'加入条件性扫描闭合窗口后的最大值：{upper:.5f} ms。</p>'
            + (f'<p>检测到首个 B 部分脉冲，宽度 {timing["partial"]["width_us"]:.2f} µs；'
               '已以该部分脉冲首次越阈值作为 B 参考，未丢弃后改用下一完整扫描。'
               '此为条件性模型识别，不是直接测得物理闭合。</p>' if timing["partial"] else
               '<p>未检测到符合本模型的独立 B 部分脉冲，采用完整脉宽变化推断。</p>') +
            '<p><strong>不是物理闭合时刻的直接测量，不是严格最坏上界，不证明无抖动或全键达标。</strong>'
            '扫描窗口依赖触点稳定闭合、相邻 A/B 行及八行扫描假设。零相位 FIR 可能影响起音。</p>'
            '<p>2 µs 相位余量为分析模型假定，并非已校准的全系统误差预算。</p>'
            '<p>处理包含约 0.55 µs 毛刺填补，并保留首个长扫描脉冲之后超过 1 µs 的低脉冲；'
            '更短导通不在此模型证明范围内。</p>'
            + ('<p>已排除一个末端截断低脉冲：原始记录结束时列信号仍为低，'
               '未观测到结束边沿；未排除中间异常。完整脉冲证据仍须覆盖起音确认区间。'
               '具体范围见 review.json 的 terminal_censored_pulse。</p>' if censored else '')
            +
            f'<p>CH1/CH2 接近 ADC 上下限的样本数：{html.escape(str(rails))}；需人工检查。</p>'
            '<h2>B 参考定位与延迟标尺</h2>'
            '<img src="b_detail.png" alt="B 参考起点、模拟起音终点、延迟箭头与 CH1 局部波形">'
            '<h2>完整延迟与模拟起音放大</h2>'
            '<img src="audio_detail.png" alt="从 B 参考到模拟起音的完整间隔及阈值放大图">'
            '<h2>原始证据与计算参数</h2>'
            f'<p><a href="{html.escape(relative_link(screen_file(folder, "latency"), out))}">示波器原屏</a> · '
            f'<a href="{html.escape(relative_link(report_folder(folder, "latency") / "audio_spectrum.png", out))}">'
            '原始数据音频频谱</a> · '
            '<a href="review.json">完整计算参数与版本</a></p>'
            + budget_section +
            '<h2>方法敏感性明细</h2>'
            '<table><thead><tr><th>方法</th><th>重采样 Hz</th><th>阈值 mV</th>'
            '<th>推断 B 延迟 ms</th><th>条件性最大延迟 ms</th></tr></thead><tbody>'
            + rows + '</tbody></table>')
        (out/"report.html").write_text(page(title+" 按键延迟证据", body), encoding="utf-8")
        results.append(result)
        print(title,"method span",min(values),max(values),"conditional envelope",upper,flush=True)
    if not trial:
        (base/"evidence_review.json").write_text(json.dumps(results,indent=2),encoding="utf-8")
    return results


def generate(folder):
    out = report_folder(folder, "latency") / "evidence"
    if (out / "review.json").exists():
        number = 1
        while (out / f"review_{number:03}").exists():
            number += 1
        out = out / f"review_{number:03}"
    main(trial=folder, output=out)
    return out / "report.html"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trial", type=Path)
    parser.add_argument("--base", type=Path, default=BASE)
    args = parser.parse_args()
    main(args.base, args.trial)

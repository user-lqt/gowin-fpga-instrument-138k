"""Offline diagnostics only: selected long pulses never establish a pass."""

import hashlib
import html
import json
from pathlib import Path

import numpy as np

from measurement_files import relative_link, report_folder
from scan_latency_validation import pulses, read_csv


def summarize(data):
    t = data[:, 0]
    channels = []
    for values in data[:, 1:].T:
        starts, ends = pulses(t, values == 0, trim=True)
        widths = ends - starts
        major = widths > 10e-6
        periods = np.diff(starts[major])
        channels.append({
            "complete_low_pulses": len(starts),
            "low_pulses_under_1us": int(np.count_nonzero(widths < 1e-6)),
            "long_pulses_over_10us": int(np.count_nonzero(major)),
            "long_pulse_period_us": (
                [float(v * 1e6) for v in (min(periods), np.median(periods), max(periods))]
                if len(periods) else None),
            "long_pulse_width_us": (
                [float(v * 1e6) for v in
                 (min(widths[major]), np.median(widths[major]), max(widths[major]))]
                if major.any() else None),
        })
    overlap = (data[:, 1] == 0) & (data[:, 2] == 0)
    return {
        "kind": "scan_signal_diagnostics", "validation_status": "not_determined",
        "conditional_below_5ms": None, "rows": len(data),
        "duration_s": float(t[-1] - t[0]), "channels": channels,
        "row_overlap_total_us": float(np.sum(np.diff(t)[overlap[:-1]]) * 1e6),
        "diagnostic_selection": (
            "仅统计宽度大于 10 µs 的完整低脉冲用于排查；"
            "未将筛选结果送入延迟验收，不据此恢复 B 起点或判定达标。"),
    }


def generate(trial, csv_path, names, reason, sample_rate_hz=None, error_details=None):
    trial, csv_path = Path(trial), Path(csv_path)
    data = read_csv(csv_path, names)
    result = summarize(data)
    result.update(reason=str(reason), csv_columns=list(names),
                  rejected_event_details=error_details,
                  digital_sample_rate_hz=sample_rate_hz,
                  logic_csv_sha256=hashlib.sha256(csv_path.read_bytes()).hexdigest())
    base = report_folder(trial, "latency") / "scan_diagnostics"
    number = 1
    while (base / f"diagnostic_{number:03}").exists():
        number += 1
    output = base / f"diagnostic_{number:03}"
    output.mkdir(parents=True)
    (output / "analysis.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from polyphony_acceptance.report_chinese import configure_plot
    configure_plot()
    t = data[:, 0]
    row_starts, row_ends = pulses(t, data[:, 1] == 0, trim=True)
    major = row_starts[(row_ends - row_starts) > 10e-6]
    col_starts, col_ends = pulses(t, data[:, 3] == 0, trim=True)
    contacts = col_starts[(col_ends - col_starts) > 10e-6]
    anchors = (major[0] if len(major) else t[0], contacts[0] if len(contacts) else t[0])
    fig, axes = plt.subplots(3, 2, figsize=(13, 6), layout="constrained")
    for j, anchor in enumerate(anchors):
        left, right = anchor - 50e-6, anchor + 450e-6
        # Keep one event on each side so sparse step data remain faithful.
        first = max(0, np.searchsorted(t, left) - 1)
        last = min(len(t), np.searchsorted(t, right) + 1)
        for i, label in enumerate(("A 行", "B 行", "列母线")):
            ax = axes[i, j]
            ax.step((t[first:last] - anchor) * 1e6, data[first:last, i+1], where="post")
            ax.set(xlim=(-50, 450), ylim=(-.2, 1.2), yticks=[0, 1], ylabel=label)
            ax.grid(alpha=.2)
        axes[0, j].set_title(("记录前段", "首次列主脉冲附近")[j] + "（未滤波）")
        axes[2, j].set_xlabel("相对窗口参考点（µs）")
    fig.savefig(output / "digital_waveforms.png", dpi=160)
    plt.close(fig)

    rejected_html = ""
    if (error_details or {}).get("category") == "row_column_phase_mismatch":
        phase = error_details["column_after_A_us"]
        counts = error_details["row_core_column_low_counts"]
        result["row_column_phase_diagnostic"] = error_details
        rejected_html = (
            '<h2>行列对应未验证：不要继续重复正式测量</h2>'
            f'<p>完整列主脉冲 {error_details["column_main_pulses"]} 个；'
            f'A 行内部有列导通的窗口 {counts["A"]} 个，'
            f'B 行内部有列导通的窗口 {counts["B"]} 个。'
            f'列下降沿相对前一个 A 行下降沿的相位中位数 {phase["median"]:.3f} µs'
            f'（5%～95%：{phase["p5"]:.3f}～{phase["p95"]:.3f} µs）。</p>'
            '<p>下图右列显示首次列主脉冲附近的实测行列关系。'
            '当前数据不能确定目标键 B 起点；不能通过平移行信号或忽略碎脉冲补成有效结果。'
            '这不能单独区分目标键选择、探头对应或其他硬件原因。</p>'
            f'<p>{html.escape(error_details["action"])}</p>'
        )
        (output/"analysis.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    if error_details and error_details.get("category") == "partial_b_window":
        bs, be = error_details["b_window_logic_s"]
        cs, ce = error_details["column_low_logic_s"]
        fig, axes = plt.subplots(4, 2, figsize=(14, 8), layout="constrained")
        scale = error_details["alignment_scale"]
        offset = error_details["alignment_offset_s"]
        analog = None
        try:
            from latency_waveforms import load
            (analog, _), analog_dt, analog_evidence = load(trial)
            result["analog_comparison_raw_sha256"] = analog_evidence["raw_sha256"]
        except (OSError, ValueError, KeyError) as error:
            result["analog_comparison_unavailable"] = str(error)
        for j, bounds in enumerate(((-10., 40.), (-30., 300.))):
            left, right = bs+bounds[0]*1e-6, bs+bounds[1]*1e-6
            first = max(0, np.searchsorted(t, left)-1)
            last = min(len(t), np.searchsorted(t, right)+1)
            if analog is not None:
                s = max(0, int((scale*left+offset)/analog_dt))
                e = min(len(analog), int((scale*right+offset)/analog_dt)+1)
                axes[0, j].plot(
                    ((np.arange(s, e)*analog_dt-offset)/scale-bs)*1e6,
                    analog[s:e], lw=.8, color="#116b96")
                axes[0, j].axhline(1.5, color="#aa3344", ls=":", lw=1)
            else:
                axes[0, j].text(.1, .5, "模拟列原始数据不可用", transform=axes[0, j].transAxes)
            axes[0, j].set(ylabel="CH1 列电压 (V)",
                           title=("部分导通 B 窗口局部", "与下一帧 B 窗口对照")[j])
            for i, label in enumerate(("A 行", "B 行", "数字列"), 1):
                axes[i, j].step((t[first:last]-bs)*1e6, data[first:last, i],
                                where="post", lw=1, color="#31674a")
                axes[i, j].set(ylabel=label, ylim=(-.2, 1.2), yticks=[0, 1])
            for ax in axes[:, j]:
                ax.axvspan(0, (be-bs)*1e6, color="#087f8c", alpha=.12)
                ax.axvline((cs-bs)*1e6, color="#aa3344", ls="--", lw=.8)
                ax.set_xlim(*bounds)
                ax.grid(alpha=.2)
            axes[-1, j].set_xlabel("相对该 B 行窗口起点 (µs)，非物理闭合时刻")
        fig.savefig(output/"partial_b_window.png", dpi=160)
        plt.close(fig)
        rejected_html = (
            '<h2>本次实际阻止分析的 B 窗口</h2>'
            f'<p>B 窗口 {bs:.9f}～{be:.9f} s；'
            f'相关列低段 {cs:.9f}～{ce:.9f} s。'
            f'列低段始于 B 窗口起点后 {error_details["column_onset_from_b_start_us"]:.3f} µs，'
            f'低宽 {error_details["column_low_width_us"]:.3f} µs；'
            f'是否保持至内部窗口末尾：{"是" if error_details["column_low_reaches_core_end"] else "否"}。</p>'
            '<p>中途开始导通不等于导通后又断开。两者均不符合当前完整 B 窗口模型；'
            '不据此认定接线错误或延迟超过 5 ms，不通过挑选下一完整窗口来隐藏本次部分导通。</p>'
            '<img src="partial_b_window.png" alt="B 部分导通的模拟电压与原始行列波形">'
        )
        (output/"analysis.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    analog_prior = (error_details or {}).get("category") == "prior_analog_column_contact"
    if analog_prior:
        from latency_waveforms import load
        (column, _), dt, evidence = load(trial)
        events = error_details["events"]
        anchor = events[0]["start_s"]
        first = max(0, int((anchor-10e-6)/dt))
        last = min(len(column), int((error_details["first_main_s"]+40e-6)/dt)+1)
        fig, ax = plt.subplots(figsize=(13, 4), layout="constrained")
        ax.plot((np.arange(first, last)*dt-anchor)*1e6, column[first:last], lw=1)
        ax.axhline(1.5, color="#b0283c", ls="--")
        ax.set(xlabel="相对首个前置模拟列低（µs，示波器自身时间轴）",
               ylabel="原始 CH1（V）", title="主脉冲之前的原始模拟列接触")
        ax.grid(alpha=.2)
        fig.savefig(output/"prior_analog_contact.png", dpi=160)
        plt.close(fig)
        result["analog_comparison_raw_sha256"] = evidence["raw_sha256"]
        (output/"analysis.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        rejected_html = (
            '<h2>主脉冲前的模拟列接触</h2>'
            '<p>以下时间来自示波器，不与逻辑分析仪时间直接相减；尚未通过共同列同步。'
            '保留前置接触，不将后一个完整脉冲冒充首次接触，也不作5ms达标判定。</p>'
            '<table><tr><th>示波器记录内时间（s）</th><th>低宽（µs）</th>'
            '<th>主脉冲之前（µs）</th></tr>'
            + "".join(f'<tr><td>{e["start_s"]:.9f}</td><td>{e["width_us"]:.4f}</td>'
                      f'<td>{e["before_first_main_us"]:.3f}</td></tr>' for e in events)
            + '</table><img src="prior_analog_contact.png" alt="前置模拟列接触原始电压">'
        )
    if error_details and error_details.get("events") and not analog_prior:
        events = error_details["events"]
        intermediate = error_details.get("category") == "intermediate_pulses"
        prior_contact = error_details.get("category") == "prior_column_contact"
        event_name = ("首次主列前低段" if prior_contact else
                      "中等宽度低脉冲" if intermediate else "未解释短跳变")
        anchor = events[0]["start_s"]
        first = max(0, np.searchsorted(t, anchor-5e-6)-1)
        last = min(len(t), np.searchsorted(t, anchor+10e-6)+1)
        fig, axes = plt.subplots(3, 1, figsize=(13, 6), layout="constrained", sharex=True)
        for i, label in enumerate(("A 行", "B 行", "列母线")):
            axes[i].step((t[first:last]-anchor)*1e6, data[first:last, i+1], where="post")
            axes[i].set(ylabel=label, ylim=(-.2, 1.2), yticks=[0, 1], xlim=(-5, 10))
            axes[i].axvline(0, color="#b0283c", ls="--")
            axes[i].grid(alpha=.2)
        axes[0].set_title(f"{event_name}局部（原始数字事件，未滤波）")
        axes[-1].set_xlabel(f"相对首个{event_name}（µs）")
        fig.savefig(output/"rejected_events.png", dpi=160)
        plt.close(fig)
        counts = (
            f'首次完整主列前超过1微秒的低段 {len(events)} 个；'
            '不能把它们直接视作静止段，也不能将首次完整主列当作首次物理接触。'
            '这些事件不是记录开头为低的证明，不作5ms达标判定。'
            if prior_contact else
            f'1～10 µs 独立低脉冲 {len(events)} 个；不作为边界毛刺排除。'
            if intermediate else
            f'不符合边界规则 {error_details["rejected_count"]} 个；'
            f'该通道验证区间短跳变总数 {error_details["total_short_count"]} 个。'
            '总数不等于违规数；最多列出前十个事件。')
        rejected_html = (
            '<h2>实际阻止分析的事件</h2>'
            f'<p>通道：{html.escape(error_details["channel"])}；'
            + counts + '</p>'
            '<table><tr><th>开始时间（s）</th><th>低宽（µs）</th>'
            '<th>到最近主扫描边界（µs）</th></tr>'
            + "".join(
                f'<tr><td>{e["start_s"]:.9f}</td><td>{e["width_us"]:.4f}</td>'
                + (f'<td>{e["distance_to_scan_boundary_us"]:.4f}</td></tr>'
                   if "distance_to_scan_boundary_us" in e else '<td>未用于此项分类</td></tr>')
                for e in events)
            + '</table><img src="rejected_events.png" alt="实际阻止分析的短跳变局部">'
        )

    rows = []
    for label, channel in zip(("A 行", "B 行", "列母线"), result["channels"]):
        def fmt(values):
            return "不足两个主脉冲" if values is None else " / ".join(f"{v:.4f}" for v in values)
        rows.append(
            f'<tr><td>{label}</td><td>{channel["complete_low_pulses"]}</td>'
            f'<td>{channel["low_pulses_under_1us"]}</td>'
            f'<td>{fmt(channel["long_pulse_period_us"])}</td>'
            f'<td>{fmt(channel["long_pulse_width_us"])}</td></tr>')
    summary = (
        "联合验证未完成，不代表延迟超过 5 ms。"
        "以下统计区分短跳变与较长低脉冲，但不替代原始信号验证。")
    page = (
        '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>扫描信号诊断</title>'
        '<style>body{font:16px sans-serif;max-width:1100px;margin:24px auto;padding:16px}'
        'table{border-collapse:collapse}td,th{border:1px solid #aaa;padding:8px}img{max-width:100%}</style>'
        '<h1>扫描信号诊断：未作达标判定</h1>'
        f'<p>{summary}</p><p>验证原始错误：{html.escape(str(reason))}</p>'
        + rejected_html +
        '<h2>完整逻辑记录统计</h2><p>以下总数包含采集等待段，不等于本次违反边界规则的数量。</p>'
        '<table><tr><th>通道</th><th>完整低脉冲数</th><th>不足 1 µs 的低脉冲数</th>'
        '<th>主脉冲周期：最小 / 中位 / 最大（µs）</th>'
        '<th>主脉冲低宽：最小 / 中位 / 最大（µs）</th></tr>'
        + "".join(rows)
        + f'</table><p>A/B 同时读为低电平的总时长：{result["row_overlap_total_us"]:.4f} µs。</p>'
        '<p>当前验证采用低有效八行扫描模型，包含行宽、周期及有界 A/B 交界偏差检查。'
        '主周期接近 200 µs 不足以证明行切换边界或首次 B 导通准确。'
        '数字短跳变不能单独区分电平恢复、阈值穿越或其他原因，不等于接线错误。</p>'
        f'<p>{result["diagnostic_selection"]}</p>'
        '<img src="digital_waveforms.png" alt="未滤波的数字信号">'
        f'<p><a href="{html.escape(relative_link(csv_path, output), quote=True)}">原始数字 CSV</a>'
        ' · <a href="analysis.json">统计参数与原始数据哈希</a></p></html>'
    )
    (output / "report.html").write_text(page, encoding="utf-8")
    return output / "report.html", result

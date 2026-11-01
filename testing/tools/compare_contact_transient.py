"""Offline contact diagnostics, never a replacement for joint validation."""

import argparse
import hashlib
import html
import json
from pathlib import Path

import numpy as np

from latency_waveforms import load
from measurement_files import report_folder
from scan_latency_validation import fit_edges, pulses, read_csv
from scope_column_pulses import extract


def diagnostic_alignment(logic_starts, logic_ends, scope_starts, scope_ends):
    """Fit later complete pulses, explicitly excluding initial contact."""
    n = len(scope_starts)
    if n < 23 or len(logic_starts) < n:
        raise ValueError("后续完整共同列脉冲不足，不能开展局部对照。")
    fits = []
    for skip in (1, 3, 10):
        scale, offset, residual = fit_edges(
            logic_starts[skip:n], logic_ends[skip:n],
            scope_starts[skip:], scope_ends[skip:])
        fits.append(dict(
            skipped_initial_pulses=skip, pairs=n-skip, scale=scale,
            offset_s=offset, max_residual_us=residual*1e6,
            mapped_first_main_s=float(scale*logic_starts[0]+offset),
        ))
    selected = fits[1]
    if any(abs(f["scale"]-1) > .002 or f["max_residual_us"] > 2.1 for f in fits):
        raise ValueError("后续列脉冲配对不稳定；不能用局部对齐图解释首次接触。")
    return dict(
        fits=fits, selected=selected,
        first_anchor_spread_us=float(np.ptp([f["mapped_first_main_s"] for f in fits])*1e6),
        assumption="按首次完整主脉冲编号配对；仅供诊断，不构成唯一同步或计量验收。",
    )


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def generate(trial, output_root=None):
    trial = Path(trial).resolve()
    joint = json.loads((trial/"joint_capture.json").read_text(encoding="utf-8"))
    if not joint.get("same_press_user_confirmed"):
        raise ValueError("没有同一次按压确认，不能作首次接触对照。")
    csv_path = (trial/joint["digital_csv"]).resolve()
    sources = [trial/name for name in (
        "ch1.bin", "ch2.bin", "metadata.json", "trial.json", "joint_capture.json")]
    sources.append(csv_path)
    before = {str(p): digest(p) for p in sources}
    data = read_csv(csv_path, ["Time [s]", "Channel 0", "Channel 1", "Channel 2"])
    (column, _), dt, evidence = load(trial)
    ss, se, _ = extract(column, dt)
    ss, se = ss*dt, se*dt
    main = se-ss > 10e-6
    ss, se = ss[main], se[main]
    ls, le = pulses(data[:, 0], data[:, 3] == 0, trim=True)
    main = le-ls > 10e-6
    ls, le = ls[main], le[main]
    fit = diagnostic_alignment(ls, le, ss, se)
    scale, offset = fit["selected"]["scale"], fit["selected"]["offset_s"]
    anchor = fit["selected"]["mapped_first_main_s"]
    mapped = data[:, 0]*scale+offset
    first = max(0, np.searchsorted(mapped, anchor-20e-6)-1)
    last = min(len(mapped), np.searchsorted(mapped, anchor+70e-6)+1)
    begin, end = max(0, int((anchor-20e-6)/dt)), min(len(column), int((anchor+70e-6)/dt))
    scope_t = np.arange(begin, end)*dt
    voltage = column[begin:end]
    rows = {}
    for name, index in (("A", 1), ("B", 2), ("column", 3)):
        s, e = pulses(data[:, 0], data[:, index] == 0, trim=True)
        keep = (e > ls[0]-20e-6) & (s < ls[0]+70e-6)
        rows[name] = [dict(start_us=float((scale*x+offset-anchor)*1e6),
                           end_us=float((scale*y+offset-anchor)*1e6),
                           width_us=float(scale*(y-x)*1e6))
                      for x, y in zip(s[keep], e[keep])]
    short_contact = [r for r in rows["column"] if r["start_us"] < 0]
    all_short_inside_a = bool(short_contact) and all(
        any(a["start_us"] <= r["start_us"] and r["end_us"] <= a["end_us"]
            for a in rows["A"]) for r in short_contact)
    bs, be = pulses(data[:, 0], data[:, 2] == 0, trim=True)
    bmain = (be-bs > 10e-6) & (bs >= ls[0])
    b_windows = []
    for start, stop in list(zip(bs[bmain], be[bmain]))[:3]:
        core_start, core_stop = start+2e-6, stop-2e-6
        core = (data[:, 0] >= core_start) & (data[:, 0] < core_stop)
        preceding = max(0, np.searchsorted(data[:, 0], core_start, side="right")-1)
        values = np.r_[data[preceding, 3], data[core, 3]]
        b_windows.append(dict(
            start_us=float((scale*start+offset-anchor)*1e6),
            end_us=float((scale*stop+offset-anchor)*1e6),
            core_column_all_low=bool(np.all(values == 0)),
            core_column_all_high=bool(np.all(values == 1)),
        ))
    thresholds = []
    for threshold in (.8, 1.2, 1.5, 1.8, 2.0):
        s, e = pulses(scope_t, voltage < threshold, trim=True)
        thresholds.append(dict(
            threshold_v=threshold, low_segments=len(s),
            first_crossing_us=float((s[0]-anchor)*1e6) if len(s) else None,
            segments_over_1us=[
                dict(start_us=float((x-anchor)*1e6), width_us=float((y-x)*1e6))
                for x, y in zip(s, e) if y-x > 1e-6],
        ))
    result = dict(
        kind="contact_transient_comparison", diagnostic_only=True,
        conditional_below_5ms=None, acceptance=None, alignment=fit,
        scope_sample_interval_ns=dt*1e9,
        logic_sample_rate_hz=joint.get("digital_sample_rate_hz"),
        raw_scope_evidence=evidence, source_sha256=before,
        reference="逻辑分析仪首次 >10 µs 主列脉冲起点，经后续脉冲拟合映射；不是 B 触点闭合时刻。",
        closed_scope_first_start_relative_us=float((ss[0]-anchor)*1e6),
        closed_scope_first_end_relative_us=float((se[0]-anchor)*1e6),
        digital_events=rows, analog_threshold_sensitivity=thresholds,
        initial_short_pulses_all_inside_a=all_short_inside_a,
        first_three_b_scan_windows=b_windows,
        limitations=[
            "逻辑分析仪实际输入阈值未知；不同记录仪、阈值及带宽可能给出不同跳变时刻。",
            "后续脉冲拟合排除了首次三个脉冲，只用于展示接触瞬态，不能替换全边沿验收。",
            "不推断真实物理闭合时刻，不修改原失败结果，不计算或宣称延迟达标。",
        ],
    )
    after = {str(p): digest(p) for p in sources}
    if after != before:
        raise ValueError("分析期间原始证据发生变化，停止生成报告。")
    result["source_hashes_unchanged"] = True
    base = (Path(output_root) if output_root else report_folder(trial, "latency"))/"contact_comparison"
    number = 1
    while (base/f"comparison_{number:03}").exists():
        number += 1
    output = base/f"comparison_{number:03}"
    output.mkdir(parents=True, exist_ok=False)

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from polyphony_acceptance.report_chinese import configure_plot
    configure_plot()
    fig, axes = plt.subplots(
        4, 2, figsize=(15, 9), layout="constrained",
        gridspec_kw={"height_ratios": [2.5, 1, 1, 1]})
    for j, limits in enumerate(((-15, 55), (-8, 6))):
        ax = axes[0, j]
        ax.plot((scope_t-anchor)*1e6, voltage, color="#116b96", lw=.9,
                label="示波器 CH1 原始电压")
        ax.axhline(1.5, color="#aa3344", ls="--", lw=1, label="分析阈值 1.5 V")
        ax.set(ylabel="列电压 (V)", title=("首次接触及 A/B 行窗口", "首次接触放大")[j])
        ax.legend(fontsize=9, loc="upper right")
        for i, (name, label) in enumerate((("A", "A 行"), ("B", "B 行"), ("column", "数字列")), 1):
            axes[i, j].step((mapped[first:last]-anchor)*1e6,
                            data[first:last, i], where="post", color="#31674a", lw=1)
            axes[i, j].set(ylabel=label, yticks=[0, 1], ylim=(-.2, 1.2))
        for ax in axes[:, j]:
            ax.set_xlim(*limits)
            ax.axvline(0, color="#555555", lw=.8, ls=":")
            ax.grid(alpha=.2)
        axes[-1, j].set_xlabel("相对首次数字主列脉冲 (µs)，非 B 闭合时刻")
    fig.savefig(output/"contact_comparison.png", dpi=160)
    plt.close(fig)
    (output/"analysis.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    table = "".join(
        f"<tr><td>{r['threshold_v']:.1f}</td><td>{r['first_crossing_us']}</td>"
        f"<td>{r['low_segments']}</td></tr>" for r in thresholds)
    b_table = "".join(
        f"<tr><td>{r['start_us']:.4f}</td><td>{r['end_us']:.4f}</td>"
        f"<td>{'全低' if r['core_column_all_low'] else '全高' if r['core_column_all_high'] else '有跳变'}</td></tr>"
        for r in b_windows)
    text = (
        "<!doctype html><html lang='zh-CN'><meta charset='utf-8'>"
        "<title>首次接触离线对照</title><style>"
        "body{font-family:'Microsoft YaHei',sans-serif;max-width:1400px;margin:28px auto;"
        "padding:0 20px;line-height:1.7;color:#222}img{width:100%}"
        "td,th{border:1px solid #aaa;padding:6px 14px}table{border-collapse:collapse}"
        "</style><h1>首次接触离线对照（仅诊断）</h1>"
        f"<p>记录：{html.escape(str(trial))}</p>"
        "<p><strong>原失败结果保持不变；本报告不构成延迟达标结论。</strong></p>"
        "<p>零点为首次数字主列脉冲，不是 B 物理闭合。使用后续共同列脉冲拟合两台仪器时间轴，"
        "首次三个脉冲未参与选定拟合；放大图保留全部原始跳变，不做形态学填补。</p>"
        f"<p>后续拟合最大残差 {fit['selected']['max_residual_us']:.4f} µs；"
        f"排除 1/3/10 个初始脉冲时参考点变化 {fit['first_anchor_spread_us']:.4f} µs。"
        f"现有填补算法给出的首次示波器脉冲起点在零点前 {-result['closed_scope_first_start_relative_us']:.4f} µs。</p>"
        f"<p>首次主列脉冲前局部短跳变共 {len(short_contact)} 个；"
        f"这些短跳变是否全部位于 A 行有效窗口内：{'是' if all_short_inside_a else '否'}。"
        "这不代表可以无条件忽略其它位置的短跳变。</p>"
        "<img src='contact_comparison.png' alt='示波器原始列电压与逻辑分析仪行列对照'>"
        "<h2>随后三个 B 扫描窗口</h2>"
        "<p>列状态只检查每个窗口内部，边界各排除 2 µs；不是物理闭合判定。</p>"
        "<table><tr><th>窗口起点 (µs)</th><th>窗口终点 (µs)</th><th>内部列状态</th></tr>"
        f"{b_table}</table>"
        "<h2>局部模拟阈值敏感性</h2>"
        "<p>此表仅显示同一原始电压在不同阈值下的差异，不是挑选最佳阈值，也不是误差上界。</p>"
        "<table><tr><th>阈值 V</th><th>首次低于阈值 (µs)</th><th>局部低段数量</th></tr>"
        f"{table}</table><h2>证据边界</h2><ul>"
        + "".join(f"<li>{html.escape(s)}</li>" for s in result["limitations"])
        + "</ul><p>原始文件前后哈希一致。详细数据见 analysis.json。</p></html>"
    )
    (output/"report.html").write_text(text, encoding="utf-8")
    return output, result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="首次接触原始模拟/数字波形离线对照，仅诊断")
    parser.add_argument("trial", type=Path)
    parser.add_argument("--report-root", type=Path, help="跨软件目录分析时显式指定该记录的报告目录")
    args = parser.parse_args()
    folder, result = generate(args.trial, args.report_root)
    print(folder/"report.html")
    print(json.dumps(result["alignment"], ensure_ascii=False, indent=2))

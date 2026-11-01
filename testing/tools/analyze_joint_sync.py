"""Offline pulse-pairing diagnostics, never a joint latency acceptance."""

import argparse
import hashlib
import html
import json
from pathlib import Path

import numpy as np
from scipy.ndimage import binary_closing

from measurement_files import relative_link, report_folder
from scan_latency_validation import pulses, read_csv


def analyze(trial, digital_csv):
    trial, digital_csv = Path(trial), Path(digital_csv)
    data = read_csv(digital_csv, ("Time [s]", "Channel 0", "Channel 1", "Channel 2"))
    t = data[:, 0]
    starts, ends = pulses(t, data[:, 3] == 0, trim=True)
    keep = ends - starts > 10e-6
    starts, ends = starts[keep], ends[keep]
    meta = json.loads((trial / "metadata.json").read_text(encoding="utf-8"))
    p = list(map(float, meta["CH1"]["preamble"].split(",")))
    raw = (trial / "ch1.bin").read_bytes()
    voltage = (np.frombuffer(raw, dtype=np.uint8).astype(float) - p[8] - p[9]) * p[7]
    scope_t = np.arange(len(voltage)) * p[4]
    low = binary_closing(voltage < 1.5, structure=np.ones(max(1, round(.55e-6 / p[4]))))
    scope_s, scope_e = pulses(scope_t, low)
    keep = scope_e - scope_s > 10e-6
    scope_s, scope_e = scope_s[keep], scope_e[keep]
    n = len(scope_s)
    if n < 20 or len(starts) < n + 2:
        raise ValueError("完整列主脉冲不足以执行候选配对诊断。")
    # Ignore first-contact partial pulses only in this diagnostic fit.
    # This is not sufficient to establish a unique recorder synchronization.
    alternatives = []
    for shift in (-2, -1, 0, 1, 2):
        si = np.arange(max(1, 1-shift), min(n, len(starts)-shift))
        li = si + shift
        x, y = starts[li], scope_s[si]
        scale, intercept = np.polyfit(x-x[0], y-y[0], 1)
        offset = y[0] - scale*x[0] + intercept
        residual = y - (scale*x+offset)
        alternatives.append(dict(
            logic_index_minus_scope_index=shift, pairs=len(si),
            scale=float(scale), offset_s=float(offset),
            max_falling_edge_residual_us=float(np.max(abs(residual))*1e6)))
    candidate = alternatives[2]
    scale, offset = candidate["scale"], candidate["offset_s"]
    la_width = (ends[:n]-starts[:n])*1e6
    scope_width = (scope_e-scope_s)*1e6
    width_delta = scope_width - la_width
    mismatches = np.flatnonzero(abs(width_delta) > 2)
    discrepancies = []
    for i in mismatches:
        mask = (scope_t >= scope_s[i]+30e-6) & (scope_t < scope_s[i]+45e-6)
        discrepancies.append(dict(
            pulse_number=int(i+1), logic_width_us=float(la_width[i]),
            scope_width_us=float(scope_width[i]),
            scope_voltage_30_to_45us_percentiles_V=np.percentile(
                voltage[mask], [0, 50, 100]).tolist()))
    result = dict(
        kind="joint_sync_diagnostics", validation_status="not_determined",
        conditional_below_5ms=None,
        scope_ch1_sha256=hashlib.sha256(raw).hexdigest(),
        logic_csv_sha256=hashlib.sha256(digital_csv.read_bytes()).hexdigest(),
        diagnostic_only=True, candidate_fits=alternatives,
        pulse_width_discrepancies=discrepancies,
        limitations=[
            "仅检查宽于 10 µs 的列主脉冲，示波器沿用 1.5 V 阈值与 0.55 µs 闭运算。",
            "候选拟合排除首个接触脉冲；周期性下降沿不能独立建立唯一同步。",
            "偏移一帧的候选也可能有小残差；未据此恢复 B 起点或计算联合达标结论。",
            "数字记录与模拟阈值记录存在差异，原因未确定，不能据此认定接线或驱动错误。",
        ])
    report_base = report_folder(trial, "latency")
    for parent in trial.resolve().parents:
        if (parent.name == "latency" and parent.parent.name == "raw"
                and parent.parent.parent.name == "measurements"):
            report_base = (parent.parent.parent / "reports" / "latency"
                           / trial.resolve().relative_to(parent))
            break
    base = report_base / "sync_diagnostics"
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
    fig, axes = plt.subplots(3, 1, figsize=(12, 9), layout="constrained")
    indices = [0] + list(mismatches[mismatches != 0][:1])
    indices += [min(indices[-1]+1, n-1)]
    for ax, i in zip(axes, indices):
        anchor = scope_s[i]
        lt = scale*t+offset
        left, right = anchor-5e-6, anchor+65e-6
        a = max(0, np.searchsorted(lt, left)-1)
        b = min(len(t), np.searchsorted(lt, right)+1)
        mask = (scope_t >= left) & (scope_t <= right)
        ax.plot((scope_t[mask]-anchor)*1e6, voltage[mask], label="示波器 CH1 原始电压", lw=.7)
        ax.step((lt[a:b]-anchor)*1e6, data[a:b, 3]*3.3, where="post",
                label="逻辑分析仪列信号（0/1 映射为 0/3.3，仅便于比较）", lw=1)
        ax.axhline(1.5, color="#777777", ls=":", label="示波器分析阈值 1.5 V")
        ax.set(xlim=(-5, 65), ylim=(-.3, 3.8), xlabel="相对候选脉冲起点（µs）", ylabel="电压 / 数字映射",
               title=f"第 {i+1} 个主脉冲：逻辑低宽 {la_width[i]:.3f} µs；示波器低宽 {scope_width[i]:.3f} µs")
        ax.grid(alpha=.2)
    axes[0].legend(fontsize=8, loc="lower right")
    fig.suptitle("仅诊断：按序配对的候选时间轴，未证明唯一同步", fontsize=13)
    fig.savefig(output / "pulse_comparison.png", dpi=160)
    plt.close(fig)
    rows = "".join(
        f'<tr><td>{v["pulse_number"]}</td><td>{v["logic_width_us"]:.3f}</td>'
        f'<td>{v["scope_width_us"]:.3f}</td></tr>' for v in discrepancies)
    fits = "".join(
        f'<tr><td>{v["logic_index_minus_scope_index"]:+d}</td>'
        f'<td>{v["max_falling_edge_residual_us"]:.4f}</td></tr>' for v in alternatives)
    notes = "".join(f"<li>{html.escape(v)}</li>" for v in result["limitations"])
    links = "".join(
        f'<li><a href="{html.escape(relative_link(path, output), quote=True)}">{label}</a></li>'
        for path, label in ((digital_csv, "逻辑分析仪原始 CSV"),
                            (trial / "metadata.json", "示波器采集参数")))
    (output / "report.html").write_text(
        '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>联合同步排查</title>'
        '<style>body{font:16px sans-serif;max-width:1100px;margin:32px auto;padding:16px}'
        'td,th{border:1px solid #bbb;padding:8px}table{border-collapse:collapse}img{width:100%}</style>'
        '<h1>联合同步排查：尚未建立唯一同步</h1>'
        '<p>按序配对时，首个接触脉冲与首次加宽附近存在不一致。'
        '周期性下降沿拟合残差小，不代表已排除一帧错位。此报告不判定延迟是否小于 5 ms。</p>'
        '<h2>低宽差超过 2 µs 的候选脉冲</h2><table><tr><th>主脉冲序号</th>'
        '<th>逻辑低宽 µs</th><th>示波器低宽 µs</th></tr>' + rows + '</table>'
        '<h2>不同配对偏移的下降沿拟合</h2><table><tr><th>逻辑序号减示波器序号</th>'
        '<th>最大下降沿残差 µs</th></tr>' + fits + '</table>'
        '<img src="pulse_comparison.png" alt="候选同步下的原始电压和数字列信号比较">'
        f'<ul>{notes}</ul><ul>{links}</ul><a href="analysis.json">诊断结果及原始数据哈希</a>',
        encoding="utf-8")
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("trial", type=Path)
    parser.add_argument("digital_csv", type=Path)
    args = parser.parse_args()
    print(analyze(args.trial, args.digital_csv))

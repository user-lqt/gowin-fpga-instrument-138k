"""Offline, source-labelled frequency evidence; never synthesize capture data."""
from pathlib import Path
import csv
import html

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
try:
    from .report_chinese import LABELS, configure_plot, display_value, selection_name, source_name, verdict
except ImportError:
    from report_chinese import LABELS, configure_plot, display_value, selection_name, source_name, verdict


def escape(value):
    return html.escape(str(value), quote=True)


def page(title, content):
    return f"""<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{escape(title)}</title><style>
body{{font:15px system-ui,sans-serif;margin:24px;color:#202b30;background:#f8fafb}}
main{{max-width:1400px;margin:auto}}h1{{font-size:24px}}h2{{font-size:20px;margin-top:32px}}
img{{width:100%;height:auto;background:white}}table{{border-collapse:collapse;width:100%;background:white}}
th,td{{padding:8px 12px;border-bottom:1px solid #dce3e8;text-align:right}}
th{{background:#e8eff2;position:sticky;top:0}}td:first-child,th:first-child{{text-align:left}}
.off{{background:#fff0f1}}a{{color:#08776e}}p{{line-height:1.6}}.meta{{color:#50616b}}
</style><main><h1>{escape(title)}</h1>{content}</main></html>"""


def envelope(hz, magnitude, low, high, limit=40000):
    """Keep the maximum and its actual frequency in each display bucket."""
    index = np.flatnonzero((hz >= low) & (hz <= high))
    if index.size <= limit:
        return hz[index], magnitude[index]
    stride = (index.size + limit - 1) // limit
    usable = index.size // stride * stride
    groups = index[:usable].reshape(-1, stride)
    picked = groups[np.arange(len(groups)), np.argmax(magnitude[groups], axis=1)]
    if usable < index.size:
        tail = index[usable:]
        picked = np.append(picked, tail[np.argmax(magnitude[tail])])
    return hz[picked], magnitude[picked]


def db(values, reference):
    return 20 * np.log10(np.maximum(values, 1e-20) / max(reference, 1e-20))


def save_overview(folder, result, hz, magnitude):
    configure_plot()
    rows = result["rows"]
    reference = float(np.median([r["amplitude_peak"] for r in rows if r["enabled"]]))
    fig, ax = plt.subplots(figsize=(15, 6), layout="constrained")
    band = (hz >= 500) & (hz <= rows[-1]["nominal_hz"] + 200)
    ax.plot(hz[band], db(magnitude[band], reference), color="#177267", lw=.8)
    for row in rows:
        ax.axvline(row["nominal_hz"], color="#b0283c" if not row["enabled"] else "#888888",
                   alpha=.6 if not row["enabled"] else .15)
    ax.set(xlabel="频率（Hz）", ylabel="相对开启声部谱峰中位数的幅度（dB）",
           ylim=(-90, 15), title=(
               f"{source_name(result['source'])} | {result['voices']} 声部 | "
               f"{selection_name(result['selection'])} | 工具自检：{verdict(result['spectral_check'])} | "
               f"匹配 {result['matched_enabled_peaks']}/{result['expected_peaks']} 个目标"))
    ax.grid(alpha=.2)
    fig.savefig(Path(folder) / "spectrum.png", dpi=160)
    plt.close(fig)


def save_details(folder, result, hz, magnitude, preserve_plot=False):
    configure_plot()
    folder = Path(folder)
    rows = result["rows"]
    reference = float(np.median([r["amplitude_peak"] for r in rows if r["enabled"]]))
    low, high = rows[0]["nominal_hz"] - 100, rows[-1]["nominal_hz"] + 100
    x, y = envelope(hz, magnitude, low, high)
    # Plot envelope is for viewing only; peak checks still use full FFT arrays.
    if not preserve_plot:
        np.savez_compressed(folder / "spectrum_plot.npz", hz=x, magnitude=y,
                            reference=reference)
    zooms = []
    for start in range(0, len(rows), 8):
        part = rows[start:start + 8]
        left, right = part[0]["predicted_hz"] - 45, part[-1]["predicted_hz"] + 45
        zx, zy = envelope(hz, magnitude, left, right, 14000)
        fig, ax = plt.subplots(figsize=(14, 4.5), layout="constrained")
        ax.plot(zx, db(zy, reference), color="#087f8c", lw=.8, label="实测 FFT 频谱")
        for j, row in enumerate(part):
            ax.axvline(row["nominal_hz"], color="#d98c22", ls="--", lw=.8,
                       label="设计频率" if j == 0 else None)
            if row["present"]:
                level = db(row["amplitude_peak"], reference)
                ax.plot(row["measured_hz"], level, "o", color="#087f8c", ms=3)
                ax.annotate(f"声部{row['voice']:02d}\n{row['measured_hz']:.3f} Hz",
                            (row["measured_hz"], level), xytext=(0, 10 + 20*(j % 2)),
                            textcoords="offset points", ha="center", fontsize=8)
            else:
                ax.text(row["predicted_hz"], 7, f"声部{row['voice']:02d}\n未检出目标",
                        color="#ba3949", ha="center", fontsize=8)
        ax.set(xlim=(left, right), ylim=(-90, 25), xlabel="频率（Hz）",
               ylabel="相对开启声部谱峰中位数的幅度（dB）",
               title=f"{source_name(result['source'])} | 声部 {part[0]['voice']:02d}～{part[-1]['voice']:02d}")
        ax.grid(alpha=.18)
        ax.legend(loc="lower right", fontsize=8)
        name = f"zoom_{part[0]['voice']:02d}_{part[-1]['voice']:02d}.png"
        fig.savefig(folder / name, dpi=150)
        plt.close(fig)
        zooms.append(name)
    detail = []
    for row in rows:
        item = dict(row)
        # An OFF noise maximum is not a measured oscillator frequency.
        item["frequency_error_hz"] = (
            row["measured_hz"] - row["nominal_hz"]
            if row["enabled"] and row["present"] else None)
        detail.append(item)
    with (folder / "frequency_errors.csv").open("w", newline="", encoding="utf-8-sig") as out:
        writer = csv.writer(out)
        fields = list(detail[0])
        writer.writerow([LABELS.get(key, key) for key in fields])
        writer.writerows([[display_value(key, row[key]) for key in fields] for row in detail])
    fig, axes = plt.subplots(1, 2, figsize=(17, 11), layout="constrained")
    for ax, part in zip(axes, np.array_split(np.array(detail, dtype=object), 2)):
        ax.axis("off")
        data = [[f"{r['voice']:02d}", f"{r['nominal_hz']:.3f}",
                 f"{r['measured_hz']:.3f}" if r["frequency_error_hz"] is not None else "--",
                 f"{r['frequency_error_hz']:+.3f}" if r["frequency_error_hz"] is not None else "--",
                 "开启" if r["enabled"] else "关闭"] for r in part]
        table = ax.table(cellText=data, colLabels=["声部", "设计频率 Hz", "实测频率 Hz",
                                                  "偏差 Hz", "状态"],
                         bbox=[0, 0, 1, .96], colWidths=[.12, .26, .26, .23, .13])
        table.auto_set_font_size(False)
        table.set_fontsize(9)
        for (r, c), cell in table.get_celld().items():
            cell.set_edgecolor("#dce3e8")
            cell.set_facecolor("#e8eff2" if r == 0 else "white")
    fig.suptitle(f"{source_name(result['source'])} | {len(rows)} 个频率目标\n"
                 "频率偏差 = 实测频率 - 设计频率；关闭声部不估计音调频率",
                 fontsize=13)
    fig.savefig(folder / "frequency_errors.png", dpi=140)
    plt.close(fig)
    body = (
        f"<p class='meta'>{escape(source_name(result['source']))} | {result['voices']} 声部 | "
        f"{escape(selection_name(result['selection']))} | 工具自检：{escape(verdict(result['spectral_check']))}<br>"
        f"记录时长 {result['record_seconds']:.6f} s；FFT 频点间隔 {result['bin_spacing_hz']:.6f} Hz；"
        f"共同频率缩放拟合系数 {result['clock_ratio']:.8f}。"
        "频率显示的小数位数不代表仪器测量准确度。<br>"
        "橙色虚线：设计频率。圆点标注：实测 FFT 频点的幅度最大位置。"
        "关闭声部不把噪声最大值作为音调频率报告。<br>"
        "此处通过/未通过为工具自检结果；自检阈值不是赛题直接规定，不能替代最终比赛验收。"
        "频谱峰数也不能单独证明 RTL 振荡器的独立性。</p>"
        "<h2>频谱总览</h2><img src='spectrum.png' alt='实测频谱总览'>"
        "<h2>频率明细</h2><p><a href='frequency_errors.csv'>频率偏差 CSV</a>"
        " | <a href='frequency_errors.png'>可打印频率表</a></p>"
        "<table><thead><tr><th>声部</th><th>状态</th><th>设计频率（Hz）</th>"
        "<th>实测频率（Hz）</th><th>频率偏差（Hz）</th><th>目标检查</th></tr></thead><tbody>")
    for r in detail:
        measured = f"{r['measured_hz']:.6f}" if r["frequency_error_hz"] is not None else "--"
        error = f"{r['frequency_error_hz']:+.6f}" if r["frequency_error_hz"] is not None else "--"
        body += (f"<tr class='{'' if r['enabled'] else 'off'}'><td>{r['voice']:02d}</td>"
                 f"<td>{'开启' if r['enabled'] else '关闭'}</td><td>{r['nominal_hz']:.6f}</td>"
                 f"<td>{measured}</td><td>{error}</td><td>{'符合' if r['match'] else '不符合'}</td></tr>")
    body += "</tbody></table><h2>标注放大图</h2>"
    body += "".join(f"<img src='{z}' alt='实测频率标注放大图'>" for z in zooms)
    (folder / "report.html").write_text(page("复音频率测量证据", body), encoding="utf-8")


def save_comparison(baseline, changed, full, trial, result):
    configure_plot()
    baseline, changed = Path(baseline), Path(changed)
    if not all((folder / "spectrum_plot.npz").exists() for folder in (baseline, changed)):
        return
    with np.load(baseline / "spectrum_plot.npz", allow_pickle=False) as a, \
            np.load(changed / "spectrum_plot.npz", allow_pickle=False) as b:
        ax_data = [(a["hz"].copy(), a["magnitude"].copy()),
                   (b["hz"].copy(), b["magnitude"].copy())]
        reference = float(a["reference"])
    muted = next(r for r in trial["rows"] if not r["enabled"])
    fig, axes = plt.subplots(2, 1, figsize=(15, 9), layout="constrained")
    for ax in axes:
        for (x, y), color, label in zip(ax_data, ("#187ab0", "#c83852"), ("全声部开启", "单声部静音")):
            ax.plot(x, db(y, reference), color=color, lw=.8, alpha=.85, label=label)
        ax.axvline(muted["nominal_hz"], color="#333333", ls="--", lw=.8)
        ax.set(ylim=(-90, 20), xlabel="频率（Hz）", ylabel="相对全声部开启参考的幅度（dB）")
        ax.grid(alpha=.18)
        ax.legend()
    axes[0].set_title(f"{source_name(result['source'])} | 工具自检：{verdict(result['comparison'])} | "
                      f"声部 {muted['voice']:02d} 静音，设计频率 {muted['nominal_hz']:.3f} Hz")
    axes[1].set_xlim(muted["predicted_hz"] - 150, muted["predicted_hz"] + 150)
    axes[1].set_title("静音声部及保留的相邻声部：使用相同幅度参考")
    for row in full["rows"]:
        if abs(row["nominal_hz"] - muted["nominal_hz"]) < 150:
            axes[1].annotate(f"声部{row['voice']:02d} {row['measured_hz']:.3f} Hz",
                            (row["measured_hz"], db(row["amplitude_peak"], reference)),
                            xytext=(0, 15), textcoords="offset points", ha="center", fontsize=9)
    fig.savefig(changed / "comparison_overlay.png", dpi=160)
    plt.close(fig)
    rows = "".join(
        f"<tr><td>{r['voice']:02d}</td><td>{'开启' if r['enabled'] else '关闭'}</td>"
        f"<td>{r['normalized_change_db']:+.3f}</td><td>{'符合' if r['match'] else '不符合'}</td></tr>"
        for r in result["rows"])
    body = (f"<p>{escape(source_name(result['source']))} | 工具自检：{escape(verdict(result['comparison']))}<br>"
            f"全声部开启记录：{escape(baseline)}<br>静音记录：{escape(changed)}<br>"
            f"共同增益变化：{result['common_gain_change_db']:+.3f} dB。"
            "叠加图使用相同的全声部开启参考，不做增益归一化。工具自检不等同于比赛验收。</p>"
            "<img src='comparison_overlay.png' alt='全声部开启与静音的实测 FFT 叠加图'>"
            "<table><tr><th>声部</th><th>状态</th><th>增益归一化后的变化（dB）</th>"
            f"<th>检查</th></tr>{rows}</table>")
    (changed / "comparison.html").write_text(page("全声部开启 / 静音对照证据", body), encoding="utf-8")
    print(f"Report: {changed / 'comparison.html'}", flush=True)


def regenerate(folder):
    """Re-render saved evidence without recomputing FFT or modifying analysis."""
    import json
    folder = Path(folder)
    result = json.loads((folder / "analysis.json").read_text(encoding="utf-8"))
    with np.load(folder / "spectrum_plot.npz", allow_pickle=False) as stored:
        hz, magnitude = stored["hz"].copy(), stored["magnitude"].copy()
    save_overview(folder, result, hz, magnitude)
    save_details(folder, result, hz, magnitude, preserve_plot=True)
    return folder / "report.html"

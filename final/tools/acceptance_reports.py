"""Offline, source-labelled frequency evidence; never synthesize capture data."""
from pathlib import Path
import csv
import html

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def escape(value):
    return html.escape(str(value), quote=True)


def page(title, content):
    return f"""<!doctype html><html lang="en"><meta charset="utf-8">
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


def save_details(folder, result, hz, magnitude):
    folder = Path(folder)
    rows = result["rows"]
    reference = float(np.median([r["amplitude_peak"] for r in rows if r["enabled"]]))
    low, high = rows[0]["nominal_hz"] - 100, rows[-1]["nominal_hz"] + 100
    x, y = envelope(hz, magnitude, low, high)
    # Plot envelope is for viewing only; peak checks still use full FFT arrays.
    np.savez_compressed(folder / "spectrum_plot.npz", hz=x, magnitude=y,
                        reference=reference)
    zooms = []
    for start in range(0, len(rows), 8):
        part = rows[start:start + 8]
        left, right = part[0]["predicted_hz"] - 45, part[-1]["predicted_hz"] + 45
        zx, zy = envelope(hz, magnitude, left, right, 14000)
        fig, ax = plt.subplots(figsize=(14, 4.5), layout="constrained")
        ax.plot(zx, db(zy, reference), color="#087f8c", lw=.8, label="Measured FFT")
        for j, row in enumerate(part):
            ax.axvline(row["nominal_hz"], color="#d98c22", ls="--", lw=.8,
                       label="Nominal frequency" if j == 0 else None)
            if row["present"]:
                level = db(row["amplitude_peak"], reference)
                ax.plot(row["measured_hz"], level, "o", color="#087f8c", ms=3)
                ax.annotate(f"V{row['voice']:02d}\n{row['measured_hz']:.3f} Hz",
                            (row["measured_hz"], level), xytext=(0, 10 + 20*(j % 2)),
                            textcoords="offset points", ha="center", fontsize=8)
            else:
                ax.text(row["predicted_hz"], 7, f"V{row['voice']:02d}\nOFF / no target",
                        color="#ba3949", ha="center", fontsize=8)
        ax.set(xlim=(left, right), ylim=(-90, 25), xlabel="Frequency (Hz)",
               ylabel="dB relative to enabled-tone median",
               title=f"{result['source']} | V{part[0]['voice']:02d}-{part[-1]['voice']:02d}")
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
        writer = csv.DictWriter(out, fieldnames=list(detail[0]))
        writer.writeheader()
        writer.writerows(detail)
    fig, axes = plt.subplots(1, 2, figsize=(17, 11), layout="constrained")
    for ax, part in zip(axes, np.array_split(np.array(detail, dtype=object), 2)):
        ax.axis("off")
        data = [[f"{r['voice']:02d}", f"{r['nominal_hz']:.3f}",
                 f"{r['measured_hz']:.3f}" if r["frequency_error_hz"] is not None else "--",
                 f"{r['frequency_error_hz']:+.3f}" if r["frequency_error_hz"] is not None else "--",
                 "ON" if r["enabled"] else "OFF"] for r in part]
        table = ax.table(cellText=data, colLabels=["Voice", "Nominal Hz", "Measured Hz",
                                                  "Error Hz", "State"],
                         bbox=[0, 0, 1, .96], colWidths=[.12, .26, .26, .23, .13])
        table.auto_set_font_size(False)
        table.set_fontsize(9)
        for (r, c), cell in table.get_celld().items():
            cell.set_edgecolor("#dce3e8")
            cell.set_facecolor("#e8eff2" if r == 0 else "white")
    fig.suptitle(f"{result['source']} | {len(rows)} frequency targets\n"
                 "Error = measured - nominal; OFF has no tone-frequency estimate",
                 fontsize=13)
    fig.savefig(folder / "frequency_errors.png", dpi=140)
    plt.close(fig)
    body = (
        f"<p class='meta'>{escape(result['source'])} | {result['voices']} voices | "
        f"selection {result['selection']} | {escape(result['spectral_check'])}<br>"
        f"Record {result['record_seconds']:.6f} s; FFT bin {result['bin_spacing_hz']:.6f} Hz; "
        f"common clock fit {result['clock_ratio']:.8f}. "
        "Frequency decimals do not imply instrument accuracy.<br>"
        "Dashed orange: design frequency. Dot labels: measured FFT-bin maxima. "
        "OFF rows do not report noise maxima as tone frequencies.</p>"
        "<h2>Overview</h2><img src='spectrum.png' alt='Spectrum overview'>"
        "<h2>Frequency Details</h2><p><a href='frequency_errors.csv'>Frequency error CSV</a>"
        " | <a href='frequency_errors.png'>Printable frequency table</a></p>"
        "<table><thead><tr><th>Voice</th><th>State</th><th>Nominal Hz</th>"
        "<th>Measured Hz</th><th>Error Hz</th><th>Target check</th></tr></thead><tbody>")
    for r in detail:
        measured = f"{r['measured_hz']:.6f}" if r["frequency_error_hz"] is not None else "--"
        error = f"{r['frequency_error_hz']:+.6f}" if r["frequency_error_hz"] is not None else "--"
        body += (f"<tr class='{'' if r['enabled'] else 'off'}'><td>{r['voice']:02d}</td>"
                 f"<td>{'ON' if r['enabled'] else 'OFF'}</td><td>{r['nominal_hz']:.6f}</td>"
                 f"<td>{measured}</td><td>{error}</td><td>{'OK' if r['match'] else 'FAIL'}</td></tr>")
    body += "</tbody></table><h2>Annotated Zooms</h2>"
    body += "".join(f"<img src='{z}' alt='Annotated measured-frequency zoom'>" for z in zooms)
    (folder / "report.html").write_text(page("Polyphony Frequency Evidence", body), encoding="utf-8")


def save_comparison(baseline, changed, full, trial, result):
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
        for (x, y), color, label in zip(ax_data, ("#187ab0", "#c83852"), ("ALL", "MUTE")):
            ax.plot(x, db(y, reference), color=color, lw=.8, alpha=.85, label=label)
        ax.axvline(muted["nominal_hz"], color="#333333", ls="--", lw=.8)
        ax.set(ylim=(-90, 20), xlabel="Frequency (Hz)", ylabel="dB / ALL reference")
        ax.grid(alpha=.18)
        ax.legend()
    axes[0].set_title(f"{result['source']} | {result['comparison']} | "
                      f"MUTE V{muted['voice']:02d} at {muted['nominal_hz']:.3f} Hz")
    axes[1].set_xlim(muted["predicted_hz"] - 150, muted["predicted_hz"] + 150)
    axes[1].set_title("Muted voice and retained neighbours / same amplitude reference")
    for row in full["rows"]:
        if abs(row["nominal_hz"] - muted["nominal_hz"]) < 150:
            axes[1].annotate(f"V{row['voice']:02d} {row['measured_hz']:.3f} Hz",
                            (row["measured_hz"], db(row["amplitude_peak"], reference)),
                            xytext=(0, 15), textcoords="offset points", ha="center", fontsize=9)
    fig.savefig(changed / "comparison_overlay.png", dpi=160)
    plt.close(fig)
    rows = "".join(
        f"<tr><td>{r['voice']:02d}</td><td>{'ON' if r['enabled'] else 'OFF'}</td>"
        f"<td>{r['normalized_change_db']:+.3f}</td><td>{'OK' if r['match'] else 'FAIL'}</td></tr>"
        for r in result["rows"])
    body = (f"<p>{escape(result['source'])} | {escape(result['comparison'])}<br>"
            f"ALL: {escape(baseline)}<br>MUTE: {escape(changed)}<br>"
            f"Common gain change: {result['common_gain_change_db']:+.3f} dB. "
            "Overlay uses the same ALL reference, without gain normalization.</p>"
            "<img src='comparison_overlay.png' alt='ALL and MUTE measured FFT overlay'>"
            "<table><tr><th>Voice</th><th>State</th><th>Gain-normalized change dB</th>"
            f"<th>Check</th></tr>{rows}</table>")
    (changed / "comparison.html").write_text(page("ALL / MUTE Evidence", body), encoding="utf-8")
    print(f"Report: {changed / 'comparison.html'}", flush=True)

"""Summarize an existing offline audit without touching devices or source data."""

import argparse
import csv
import hashlib
import html
import json
from pathlib import Path
import statistics
import sys


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def render_html(lines):
    title = next((line[2:] for line in lines if line.startswith("# ")), "延迟测量汇总")
    parts, in_table = [], False
    for line in lines:
        if line.startswith("|---"):
            continue
        if line.startswith("|"):
            tag = "td" if in_table else "th"
            if not in_table:
                parts.append("<div class='table'><table>")
            parts.append("<tr>" + "".join(
                f"<{tag}>{html.escape(cell)}</{tag}>"
                for cell in line.strip("|").split("|")) + "</tr>")
            in_table = True
            continue
        if in_table:
            parts.append("</table></div>")
            in_table = False
        if line.startswith("# "):
            parts.append(f"<h1>{html.escape(line[2:])}</h1>")
        elif line.startswith("## "):
            parts.append(f"<h2>{html.escape(line[3:])}</h2>")
        elif line:
            parts.append(f"<p>{html.escape(line.removeprefix('- '))}</p>")
    if in_table:
        parts.append("</table></div>")
    return (
        '<!doctype html><html lang="zh-CN"><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        f'<title>{html.escape(title)}</title><style>'
        'body{max-width:1100px;margin:32px auto;padding:0 20px;font:16px/1.7 '
        '"Microsoft YaHei",sans-serif;color:#222}h1{font-size:26px}h2{font-size:20px}'
        '.table{overflow-x:auto}table{border-collapse:collapse;width:100%;'
        'font-variant-numeric:tabular-nums}th,td{padding:7px 10px;border-bottom:'
        '1px solid #ddd;text-align:right;white-space:nowrap}th{background:#edf3f0}'
        'th:first-child,td:first-child{text-align:left}p{overflow-wrap:anywhere}'
        '</style>' + "".join(parts) + "</html>"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("audit", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(args.output)
    app = args.app.resolve()
    sys.path.insert(0, str(app / "tools"))
    from scan_latency_validation import analyze

    audit = json.loads(args.audit.read_text(encoding="utf-8"))
    if digest(app / "tools/scan_latency_validation.py") != audit["engine_sha256"]:
        raise ValueError("分析引擎与全批次审计版本不一致，请先重新审计。")
    records = [r for r in audit["records"] if r["status"] == "available_observation"]
    if not records or len({(r["key"], r["trial_number"]) for r in records}) != len(records):
        raise ValueError("可用记录为空或包含重复试次。")
    expected_hashes = {}
    for record in records:
        if not record.get("source_sha256"):
            raise ValueError("审计记录缺少源文件哈希。")
        for filename, expected in record["source_sha256"].items():
            if filename in expected_hashes and expected_hashes[filename] != expected:
                raise ValueError("不同记录对同一源文件的哈希不一致。")
            expected_hashes[filename] = expected
    for filename, expected in expected_hashes.items():
        if digest(filename) != expected:
            raise ValueError(f"审计后源文件已改变：{filename}")

    details = []
    for record in records:
        trial = Path(record["trial"])
        relative = trial.relative_to(app / "measurements/raw/latency")
        report_root = app / "measurements/reports/latency" / relative / "scan_validation"
        matches = []
        for filename in sorted(report_root.glob("verification_*/analysis.json")):
            data = json.loads(filename.read_text(encoding="utf-8"))
            delay = (data["audio_latest_scope_s"] - data["b_window_scope_s"][0]) * 1000
            if (abs(delay - record["b_to_latest_audio_ms"]) < 1e-8
                    and abs(data["unbudgeted_timing_envelope_ms"]
                            - record["unbudgeted_envelope_ms"]) < 1e-8):
                matches.append((filename, data))
        complete = [m for m in matches if "audio_evidence" in m[1]]
        if complete:
            filename, data = complete[-1]
            recalculated = False
        else:
            link = json.loads((trial / "joint_capture.json").read_text(encoding="utf-8"))
            data, *_ = analyze(
                trial, (trial / link["digital_csv"]).resolve(),
                ("Time [s]", "Channel 0", "Channel 1", "Channel 2"),
                0, 0, True, link["digital_sample_rate_hz"], observation_only=True)
            filename = matches[-1][0] if matches else None
            recalculated = True
        delay = (data["audio_latest_scope_s"] - data["b_window_scope_s"][0]) * 1000
        if (abs(delay - record["b_to_latest_audio_ms"]) > 1e-8
                or abs(data["unbudgeted_timing_envelope_ms"]
                       - record["unbudgeted_envelope_ms"]) > 1e-8):
            raise ValueError(f"报告与审计数值不一致：{trial}")
        samples = data["audio_evidence"]["sensitivities"]
        combinations = {(s["method"], round(s["rate_Hz"]), s["threshold_mV"])
                        for s in samples}
        expected = {(m, r, t) for m in ("polyphase", "block_mean")
                    for r in (25000, 50000, 100000) for t in (10, 15, 20)}
        if len(samples) != 18 or combinations != expected:
            raise ValueError(f"起音敏感性组合不完整：{trial}")
        times = [s["onset_scope_s"] for s in samples]
        if abs(max(times) - data["audio_latest_scope_s"]) > 1e-10:
            raise ValueError("所用起音不是18项结果中的最晚值。")
        details.append(dict(
            key=record["key"], trial=record["trial_number"],
            delay_ms=delay, envelope_ms=record["unbudgeted_envelope_ms"],
            onset_spread_us=(max(times) - min(times)) * 1e6,
            sensitivities=samples, sensitivities_recalculated=recalculated,
            report=str(filename) if filename else None,
            scan_period_min_us=data["scan_period_min_us"],
            scan_period_max_us=data["scan_period_max_us"],
        ))
        print(f"K{record['key']:02d} / {record['trial_number']:03d}", flush=True)
    rows = []
    for key in range(1, 25):
        group = [r for r in details if r["key"] == key]
        if len(group) < 3:
            raise ValueError(f"K{key} 不足3次可用记录。")
        values = [r["delay_ms"] for r in group]
        rows.append(dict(
            key=key, count=len(group), min_ms=min(values),
            mean_ms=statistics.mean(values), max_ms=max(values),
            range_us=(max(values) - min(values)) * 1000,
            max_envelope_ms=max(r["envelope_ms"] for r in group),
            max_onset_spread_us=max(r["onset_spread_us"] for r in group),
        ))
    # Recheck after any legacy-record replay, before publishing the summary.
    for filename, expected in expected_hashes.items():
        if digest(filename) != expected:
            raise ValueError(f"汇总期间源文件已改变：{filename}")
    worst = max(details, key=lambda r: r["delay_ms"])
    spreads = [r["onset_spread_us"] for r in details]
    summary = dict(
        kind="full_key_observational_summary", audit_sha256=digest(args.audit),
        engine_sha256=audit["engine_sha256"], source_sha256=expected_hashes,
        device_access=False, source_files_unchanged=True,
        count=len(details), all_keys_at_least_three=True,
        min_delay_ms=min(r["delay_ms"] for r in details), worst=worst,
        max_envelope_ms=max(r["envelope_ms"] for r in details),
        onset_spread_median_us=statistics.median(spreads),
        onset_spread_max_us=max(spreads),
        resampling_phase_sweep_completed=False,
        empirical_additional_allowance_us=None, error_budget_verified=False,
        conditional_below_5ms=None, keys=rows, observations=details,
    )
    lines = [
        "# 24键联合延迟测量汇总", "",
        f"- 可用联合记录：{len(details)} 次，24 键均至少 3 次；采用全部可用记录，不挑选最快的 3 次。",
        "- 条件：钢琴音色、音量127、音效关闭、中等力度；仅代表本轮条件。",
        "- 起点：首次有效 B 行扫描窗口起点，不是直接观测到的机械闭合瞬间。",
        "- 终点：模拟音频连续至少0.1 ms超阈值的起音；取两种方法、三种采样率、三种阈值共18项中的最晚值。",
        f"- 实测间隔范围：{summary['min_delay_ms']:.6f}～{worst['delay_ms']:.6f} ms。",
        f"- 最大值：K{worst['key']}，第{worst['trial']}次。",
        f"- 计入扫描等待、同步残差、采样及边界策略后的最大包络：{summary['max_envelope_ms']:.6f} ms。",
        "- 上述包络尚未补齐额外滤波/起音分析余量及示波器时基误差，不是最终验收上界。",
        "- 未连接仪器，原始文件哈希核对通过；旧报告及原始数据未修改。",
        "", "## 全键结果", "",
        "|按键|可用次数|最小/ms|平均/ms|最大/ms|同键极差/µs|最大未补齐预算包络/ms|",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        lines.append(
            f"|K{row['key']}|{row['count']}|{row['min_ms']:.6f}|"
            f"{row['mean_ms']:.6f}|{row['max_ms']:.6f}|{row['range_us']:.3f}|"
            f"{row['max_envelope_ms']:.6f}|")
    lines += [
        "", "## 滤波与起音敏感性", "",
        f"{len(details)}次记录各18项起音结果的极差：中位数 {statistics.median(spreads):.3f} µs，"
        f"最大 {max(spreads):.3f} µs。",
        "该极差同时包含滤波方法、采样率和阈值变化，不可全部称为滤波误差。"
        "现有终点已取18项最晚值，不能再将整个极差重复加到延迟上。",
        "本汇总尚未做降采样起始相位遍历，也没有独立校准参考，"
        "因此不把此极差冒充严格误差上限，不自动填写最终额外余量。",
        "", "## 结论边界", "",
        "本轮支持：在上述测试条件下，已获得覆盖24键、每键至少3次的低于5 ms观察结果。"
        "补齐误差预算后才能形成条件性小于5 ms结论；"
        "不能据本轮少量手动按压证明所有音色、力度、复音负载下的最坏情况，"
        "也不能由此证明绝对无抖动或固定延迟。",
    ]
    args.output.mkdir(parents=True)
    (args.output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    (args.output / "summary.md").write_text("\n".join(lines), encoding="utf-8")
    with (args.output / "keys.csv").open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["按键", "可用次数", "最小/ms", "平均/ms", "最大/ms",
                         "同键极差/µs", "最大未补齐预算包络/ms", "最大起音敏感性极差/µs"])
        for row in rows:
            writer.writerow([f"K{row['key']}", *[row[k] for k in (
                "count", "min_ms", "mean_ms", "max_ms", "range_us",
                "max_envelope_ms", "max_onset_spread_us")]])
    (args.output / "summary.html").write_text(
        render_html(lines), encoding="utf-8")
    print(json.dumps({k: summary[k] for k in (
        "count", "min_delay_ms", "max_envelope_ms",
        "onset_spread_median_us", "onset_spread_max_us")}, ensure_ascii=False))


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    main()

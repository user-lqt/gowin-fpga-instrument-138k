"""Offline tone comparison. Never controls instruments or rewrites raw evidence."""

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import statistics
import sys

from audit_joint_latency import replay
from summarize_joint_latency import render_html


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    records = []
    for path in sorted((args.app / "measurements/raw/latency").rglob("trial.json")):
        manifest = json.loads(path.read_text(encoding="utf-8"))
        tone = manifest.get("instrument_user_reported")
        if tone not in ("guitar", "bianzhong", "bell"):
            continue
        record = replay(path.parent, include_audio=True)
        if record["status"] == "skipped" and manifest.get("error_message"):
            record["reason"] += "；" + manifest["error_message"]
        record.update(timbre=tone, force=manifest.get("force_label"),
                      volume=manifest.get("volume_user_reported"),
                      effects=manifest.get("effects_user_reported"),
                      firmware_sha256=manifest["version"]["sha256"])
        records.append(record)
        (args.output / "records.json").write_text(
            json.dumps(records, ensure_ascii=False, indent=2), encoding="utf-8")
        print(tone, record.get("key"), record.get("trial_number"), record["status"],
              record.get("reason", ""), flush=True)
    baseline = json.loads((args.app / "measurements/reports/evidence/"
                           "joint_replay_017/audit.json").read_text(encoding="utf-8"))
    groups = defaultdict(list)
    for record in records:
        if record["status"] == "available_observation":
            groups[record["timbre"], record["key"]].append(record)
    rows = []
    for (tone, key), group in sorted(groups.items()):
        delays = [r["b_to_latest_audio_ms"] for r in group]
        piano = [r for r in baseline["records"]
                 if r.get("key") == key and r["status"] == "available_observation"]
        piano_values = []
        for r in piano:
            trial = Path(r["trial"])
            m = json.loads((trial / "trial.json").read_text(encoding="utf-8"))
            if (m.get("instrument_user_reported") == "piano"
                    and m["version"]["sha256"] == group[0]["firmware_sha256"]
                    and m.get("force_label") == group[0]["force"]
                    and m.get("volume_user_reported") == group[0]["volume"]
                    and m.get("effects_user_reported") == group[0]["effects"]):
                for filename, expected in r["source_sha256"].items():
                    if hashlib.sha256(Path(filename).read_bytes()).hexdigest() != expected:
                        raise ValueError(f"Baseline evidence changed: {filename}")
                piano_values.append(r["b_to_latest_audio_ms"])
        rows.append(dict(
            timbre=tone, key=key, count=len(group), min_ms=min(delays),
            mean_ms=statistics.mean(delays), max_ms=max(delays),
            max_unbudgeted_envelope_ms=max(r["unbudgeted_envelope_ms"] for r in group),
            piano_count=len(piano_values),
            piano_mean_ms=statistics.mean(piano_values) if piano_values else None,
            matched_key_mean_difference_ms=(
                statistics.mean(delays)-statistics.mean(piano_values) if piano_values else None)))
    hashes = {name: value for r in records for name, value in r.get("source_sha256", {}).items()}
    for filename, expected in hashes.items():
        if hashlib.sha256(Path(filename).read_bytes()).hexdigest() != expected:
            raise ValueError(f"Raw evidence changed: {filename}")
    summary = dict(kind="representative_timbre_comparison", device_access=False,
                   source_sha256=hashes,
                   error_budget_verified=False, conditional_below_5ms=None,
                   engine_sha256=hashlib.sha256(
                       Path(__file__).with_name("scan_latency_validation.py").read_bytes()).hexdigest(),
                   groups=rows, records=records)
    (args.output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    labels = {"guitar": "吉他", "bianzhong": "编钟", "bell": "钟琴（历史标识 bell）"}
    lines = [
        "# 音色代表键延迟对比", "",
        "计时口径：B持续有效导通的首次扫描窗口起点，到18组起音算法/阈值结果中的最晚值。"
        "未连接仪器，未改原始数据；全部可用记录纳入，不挑最快三次。",
        "同键钢琴对照仅纳入相同固件文件哈希、力度标签、音量和音效的历史审核记录；"
        "烧录版本和力度均为人工声明，不是设备回读。", "",
        "|音色|按键|有效次数|最小/ms|平均/ms|最大/ms|含扫描/同步等未补齐预算包络/ms|同键钢琴均值/ms|均值差/ms|",
        "|---|---|---|---|---|---|---|---|---|"]
    for row in rows:
        piano = row["piano_mean_ms"]
        diff = row["matched_key_mean_difference_ms"]
        lines.append(
            f"|{labels[row['timbre']]}|K{row['key']}|{row['count']}|"
            f"{row['min_ms']:.6f}|{row['mean_ms']:.6f}|{row['max_ms']:.6f}|"
            f"{row['max_unbudgeted_envelope_ms']:.6f}|"
            + (f"{piano:.6f}|{diff:+.6f}|" if piano is not None else "缺少匹配|—|"))
    lines += ["", "## 无效与未完成记录", ""]
    for r in records:
        if r["status"] != "available_observation":
            lines.append(f"- {labels[r['timbre']]} K{r.get('key')} 第{r.get('trial_number')}条："
                         + r.get("reason", "未完成"))
    lines += ["", "## 结论边界", "",
              "低、中、高各一键、每键至少三次可用记录，适用于新增音色的工程代表性检查。"
              "吉他中音为K12、编钟中音为K14，不能把这两个键直接当同键对照。",
              "本表没有把钢琴批次30µs经验滤波余量自动套给新音色；未补齐预算包络不是严格误差上界。"
              "不能据代表键宣称全部按键、全部力度、全部音色的最坏延迟达标。"]
    (args.output / "summary.md").write_text("\n".join(lines), encoding="utf-8")
    (args.output / "report.html").write_text(render_html(lines), encoding="utf-8")
    print(json.dumps(rows, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    main()

"""Replay every linked complete joint capture offline; never controls devices."""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys

from scan_latency_validation import analyze
from latency_session import file_digest


def classify(reason):
    for token, code in (
            ("B 行", "b_row"), ("A 行", "a_row"), ("列信号短跳变", "column_short"),
            ("全起止沿", "alignment"), ("首帧", "startup"),
            ("部分导通", "partial_b"), ("哈希", "integrity"),
            ("1～10", "intermediate_pulse"), ("静止段", "prepress"),
            ("扫描周期不足", "missing_rows")):
        if token in reason:
            return code
    return "other"


def replay(trial, include_audio=False):
    trial = Path(trial)
    result = dict(trial=str(trial), status="unavailable")
    try:
        manifest = json.loads((trial/"trial.json").read_text(encoding="utf-8"))
        result.update(key=manifest.get("key"), trial_number=manifest.get("trial"))
        if manifest.get("status") != "complete":
            result.update(status="skipped", reason="非完整原始记录")
            return result
        link = json.loads((trial/"joint_capture.json").read_text(encoding="utf-8"))
        if link.get("same_press_user_confirmed") is not True:
            raise ValueError("关联清单未确认同一次按键。")
        csv_path = (trial/link["digital_csv"]).resolve()
        files = [trial/n for n in ("trial.json", "metadata.json", "ch1.bin", "ch2.bin",
                                   "joint_capture.json")] + [csv_path]
        before = {str(p): file_digest(p) for p in files}
        try:
            timing, *_ = analyze(
                trial, csv_path, ("Time [s]", "Channel 0", "Channel 1", "Channel 2"),
                0, 0, True, link["digital_sample_rate_hz"], observation_only=True)
            result.update(
                status="available_observation", error_budget_verified=False,
                conditional_below_5ms=None,
                b_to_latest_audio_ms=(timing["audio_latest_scope_s"]-
                                      timing["b_window_scope_s"][0])*1000,
                unbudgeted_envelope_ms=timing["unbudgeted_timing_envelope_ms"],
                initial_a_contact_transient=timing.get("initial_a_contact_transient"),
                previous_a_contact=timing.get("previous_a_contact"),
                b_midwindow_contact=timing.get("b_midwindow_contact"),
                common_recording_window=timing.get("common_recording_window"),
                model=timing["analysis_model_version"])
            if include_audio:
                result.update(
                    first_column_contact_scope_s=timing["audio_evidence"]["first_column_contact_scope_s"],
                    audio_latest_scope_s=timing["audio_latest_scope_s"],
                    audio_sensitivities=timing["audio_evidence"]["sensitivities"])
        finally:
            if before != {str(p): file_digest(p) for p in files}:
                raise ValueError("回放期间原始证据发生变化。")
            result["source_sha256"] = before
    except Exception as error:
        reason = f"{type(error).__name__}: {error}"
        result.update(status="unavailable", reason=reason, category=classify(reason))
        if getattr(error, "details", None):
            result["error_details"] = error.details
    return result


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw_root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError("审计输出目录已存在，拒绝覆盖。")
    args.output.mkdir(parents=True)
    records = []
    for path in sorted(args.raw_root.rglob("joint_capture.json")):
        result = replay(path.parent)
        records.append(result)
        (args.output/"records.json").write_text(
            json.dumps(records, ensure_ascii=False, indent=2), encoding="utf-8")
        print(result.get("key"), result.get("trial_number"), result["status"],
              result.get("reason", ""), flush=True)
    summary = dict(
        kind="offline_joint_replay", device_access=False,
        totals=dict(Counter(r["status"] for r in records)),
        failures=dict(Counter(r["category"] for r in records if "category" in r)),
        engine_sha256=hashlib.sha256(
            Path(__file__).with_name("scan_latency_validation.py").read_bytes()).hexdigest(),
        records=records,
    )
    (args.output/"audit.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    lines = ["# 联合记录离线回放", "",
             "未连接仪器。分析可用仅表示观察数据通过当前模型，不表示现场可靠或 5 ms 验收通过。",
             "", f"统计：{summary['totals']}", f"失败分类：{summary['failures']}", "",
             "| 按键 | 记录 | 状态 | 结果或原因 |", "| --- | --- | --- | --- |"]
    for r in records:
        value = (f"{r['b_to_latest_audio_ms']:.6f} ms；未补齐预算包络 "
                 f"{r['unbudgeted_envelope_ms']:.6f} ms"
                 if r["status"] == "available_observation" else r.get("reason", ""))
        lines.append(f"| K{r.get('key')} | {r.get('trial_number')} | {r['status']} | {value} |")
    (args.output/"summary.md").write_text("\n".join(lines), encoding="utf-8")
    print("TOTALS", summary["totals"], "FAILURES", summary["failures"], flush=True)


if __name__ == "__main__":
    main()

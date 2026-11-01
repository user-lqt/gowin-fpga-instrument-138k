"""Render missing reports from unchanged, successfully replayed joint evidence."""

import argparse
from collections import Counter
import json
from pathlib import Path

from latency_session import analysis_progress, file_digest
from measurement_files import directory, relative_link
from scan_latency_validation import generate_observation


def check_sources(record):
    sources = record.get("source_sha256")
    if not isinstance(sources, dict) or not sources:
        raise ValueError("审计缺少原始证据哈希，不能复用结论。")
    for name, expected in sources.items():
        if file_digest(Path(name)) != expected:
            raise ValueError(f"原始证据与审计不一致：{name}")


def failure_group(reason):
    for token, label in (
        ("扫描周期不足", "完整行扫描周期不足"),
        ("按下前基线不足", "模拟静音基线不足"),
        ("主列导通之前", "首次主列之前存在低电平"),
        ("首个主列脉冲之前", "首次主列之前存在低电平"),
        ("1～10", "独立中等宽度脉冲"),
        ("短跳变", "边界外短跳变"),
        ("首帧", "首帧证据不满足排除条件"),
        ("全起止沿", "两仪器共同列同步不通过"),
        ("模拟起音", "未检出合格模拟起音"),
        ("非完整", "原始记录不完整"),
    ):
        if token in reason:
            return label
    return "其他（见逐记录原因）"


def missing_row_details(record):
    from scan_latency_validation import read_csv
    from scan_signal_diagnostics import summarize
    trial = Path(record["trial"])
    link = json.loads((trial / "joint_capture.json").read_text(encoding="utf-8"))
    path = (trial / link["digital_csv"]).resolve()
    data = read_csv(path, ("Time [s]", "Channel 0", "Channel 1", "Channel 2"))
    stats = summarize(data)
    return dict(
        trial=str(trial), csv=str(path), csv_sha256=file_digest(path),
        duration_s=stats["duration_s"], channels=stats["channels"],
        note="仅作原始数字证据诊断；主低脉冲定义为完整且宽度超过10微秒，不用于恢复B起点。",
    )


def reconcile(audit_path, raw_root, output):
    audit_path, raw_root, output = map(Path, (audit_path, raw_root, output))
    if not raw_root.resolve().is_relative_to(directory("raw", "latency").resolve()):
        raise ValueError("请从数据所在的软件副本运行，拒绝跨副本生成报告。")
    audit = json.loads(audit_path.read_text(encoding="utf-8"))
    engine = Path(__file__).with_name("scan_latency_validation.py")
    if file_digest(engine) != audit["engine_sha256"]:
        raise ValueError("当前联合分析引擎不同于审计版本，须先重新离线回放。")
    records = audit["records"]
    # Preflight the whole audit before creating any reports.
    for record in records:
        trial = Path(record["trial"]).resolve()
        if not trial.is_relative_to(raw_root.resolve()):
            raise ValueError(f"记录不在指定固件目录：{trial}")
        if record["status"] != "skipped":
            check_sources(record)
    output.mkdir(parents=True, exist_ok=False)
    result = dict(
        kind="joint_report_reconciliation", device_access=False,
        audit_sha256=file_digest(audit_path), engine_sha256=file_digest(engine),
        rendered=[], render_errors=[], existing=[], keys=[], unavailable=[],
        missing_row_details=[],
        note="观察分析可用不等于5ms达标；不修改原始数据或放宽判定。",
    )
    try:
        for record in records:
            if record["status"] != "available_observation":
                result["unavailable"].append(dict(
                    key=record.get("key"), trial=record["trial"],
                    reason=record.get("reason", ""),
                    category=failure_group(record.get("reason", ""))))
                if "扫描周期不足" in record.get("reason", ""):
                    check_sources(record)
                    result["missing_row_details"].append(missing_row_details(record))
                    check_sources(record)
                continue
            trial = Path(record["trial"])
            number = record["trial_number"]
            current = analysis_progress(trial.parent, joint=True)
            if number in current["usable"]:
                result["existing"].append(str(trial))
                continue
            check_sources(record)
            link = json.loads((trial / "joint_capture.json").read_text(encoding="utf-8"))
            csv_path = (trial / link["digital_csv"]).resolve()
            try:
                report = generate_observation(trial, csv_path, link["digital_sample_rate_hz"])
                check_sources(record)
                state = analysis_progress(trial.parent, joint=True)
                if number not in state["usable"]:
                    raise ValueError("报告生成后仍不满足软件完整性计数。")
                result["rendered"].append(dict(trial=str(trial), report=str(report)))
                print(f"RECOVERED K{record['key']} trial_{number:03}: {report}", flush=True)
            except Exception as error:
                result["render_errors"].append(dict(trial=str(trial), error=repr(error)))
                print(f"REPORT_ERROR {trial}: {error}", flush=True)
            finally:
                (output / "result.json").write_text(
                    json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        conditions = dict(instrument_user_reported="piano", volume_user_reported="127",
                          effects_user_reported="off")
        for key in range(1, 25):
            state = analysis_progress(raw_root / f"K{key:02}" / "medium",
                                      conditions, joint=True)
            result["keys"].append(dict(key=key, **state,
                                       missing_to_3=max(0, 3-len(state["usable"]))))
        result["failure_categories"] = dict(Counter(r["category"] for r in result["unavailable"]))
        lines = [
            "# 全键联合测量复核与补测清单", "",
            "口径：指定固件、钢琴、音量127、效果关闭、中等力度，每键3条联合分析可用记录。",
            "只复用引擎哈希与全部原始证据哈希均未变的离线审计；报告生成仍重新执行完整分析。",
            "未访问仪器，未修改原始记录。观察分析可用不等于误差预算齐备或5ms验收通过。", "",
            f"补生成报告 {len(result['rendered'])} 条；生成失败 {len(result['render_errors'])} 条。",
            "可用次数包含审计之后新增的成功记录；同一条原始记录不因多份报告重复计数。", "",
            "## 每键进度", "",
            "| 按键 | 已保存完整记录 | 联合分析可用 | 可用记录编号 | 当前模型下尚缺 |",
            "| --- | --- | --- | --- | --- |",
        ]
        for row in result["keys"]:
            lines.append(
                f"| K{row['key']} | {len(row['saved'])} | {len(row['usable'])} | "
                f"{', '.join(str(n) for n in row['usable']) or '无'} | {row['missing_to_3']} |")
        lines += [
            "", "## 补测边界", "",
            "尚缺数量是当前严格联合证据口径下的缺口，不代表这些按键延迟超标。",
            "也不代表所有失败记录在任何方法下都无法恢复；本次没有通过丢弃首次接触、"
            "忽略非边界脉冲或放宽阈值来凑次数。",
            "先排查采集窗口及通道是否能记录持续扫描，再选一个缺口键试测成功；不要直接重做整轮。",
            "扫描周期不足需要检查原始行信号和记录范围，不能仅凭该错误认定接线有误。",
            "首次主列之前已有低电平、边界外跳变等情况需进一步核对原始波形，不能直接归因为用户操作。",
            "", "## 失败分类（原审计）", "",
        ]
        lines += [f"- {label}：{count} 条。" for label, count in result["failure_categories"].items()]
        if result["missing_row_details"]:
            lines += [
                "", "## 行扫描不足的原始数据核查", "",
                "下表统计完整数字记录，不是只截取按键附近；主低脉冲为宽度超过10微秒的完整低脉冲。",
                "若整条记录B行主脉冲为零，单纯延长采集或按住琴键不能补出缺失的B行证据。",
                "这不能单独证明接线错误；应核对当时实际接点、所选通道、输入电平及采集导出过程。",
                "这些记录不能靠猜测B行位置补成联合延迟结果。", "",
                "| 原始记录 | 时长 ms | A行主低脉冲 | B行主低脉冲 |",
                "| --- | --- | --- | --- |",
            ]
            for row in result["missing_row_details"]:
                path = Path(row["trial"])
                lines.append(
                    f"| {path.parent.parent.name}/{path.name} | {row['duration_s']*1000:.3f} | "
                    f"{row['channels'][0]['long_pulses_over_10us']} | "
                    f"{row['channels'][1]['long_pulses_over_10us']} |")
        lines += ["", "## 逐记录失败原因", "",
                  "| 按键 | 原始记录 | 分类 | 原因 |", "| --- | --- | --- | --- |"]
        for row in result["unavailable"]:
            path = Path(row["trial"])
            link = relative_link(path / "trial.json", output)
            reason = row["reason"].replace("|", "\\|").replace("\n", " ")
            lines.append(
                f"| K{row['key']} | [{path.name}]({link}) | {row['category']} | {reason} |")
        if result["render_errors"]:
            lines += ["", "## 报告生成异常", "",
                      *[f"- {r['trial']}：{r['error']}" for r in result["render_errors"]]]
        (output / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
        print("RENDERED", len(result["rendered"]), "ERRORS", len(result["render_errors"]),
              "MISSING", sum(row["missing_to_3"] for row in result["keys"]), flush=True)
    finally:
        (output / "result.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audit", type=Path)
    parser.add_argument("raw_root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    reconcile(args.audit, args.raw_root, args.output)


if __name__ == "__main__":
    main()

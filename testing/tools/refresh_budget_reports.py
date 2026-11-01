"""Generate new report versions for registered batch records, without devices."""

import argparse
import html
import json
from pathlib import Path

from latency_budget_report import digest
from measurement_files import ROOT, relative_link
from scan_latency_validation import generate_observation


def refresh(summary_path, output, limit=14):
    summary_path, output = Path(summary_path), Path(output)
    source = json.loads(summary_path.read_text(encoding="utf-8"))
    # The historical summary is absolute; derive the old application root
    # from its stable measurements/raw boundary, not from the current location.
    sample = Path(next(iter(source["source_sha256"])))
    index = sample.parts.index("measurements")
    original_root = Path(*sample.parts[:index])
    mapped = {ROOT / Path(name).relative_to(original_root): expected
              for name, expected in source["source_sha256"].items()}
    for filename, expected in mapped.items():
        if digest(filename) != expected:
            raise ValueError(f"原始证据已改变：{filename}")
    output.mkdir(parents=True, exist_ok=True)
    status_path = output / "progress.json"
    status = json.loads(status_path.read_text(encoding="utf-8")) if status_path.exists() else dict(
        summary_sha256=digest(summary_path), generated=[], device_access=False)
    if status["summary_sha256"] != digest(summary_path):
        raise ValueError("输入汇总已改变，不能续接。")
    done = {(r["key"], r["trial"]) for r in status["generated"]}
    by_trial = {}
    for filename in mapped:
        if filename.name == "trial.json":
            record = json.loads(filename.read_text(encoding="utf-8"))
            by_trial[(record["key"], record["trial"])] = filename.parent
    generated = 0
    for observation in source["observations"]:
        identity = observation["key"], observation["trial"]
        if identity in done:
            continue
        trial = by_trial[identity]
        link = json.loads((trial / "joint_capture.json").read_text(encoding="utf-8"))
        csv = (trial / link["digital_csv"]).resolve()
        path = generate_observation(trial, csv, link["digital_sample_rate_hz"])
        result = json.loads(path.with_name("analysis.json").read_text(encoding="utf-8"))
        delay = (result["audio_latest_scope_s"]-result["b_window_scope_s"][0])*1000
        if (abs(delay-observation["delay_ms"]) > 1e-8 or
                abs(result["unbudgeted_timing_envelope_ms"]-observation["envelope_ms"]) > 1e-8):
            raise ValueError("新版计算与原审计不一致。")
        if result["batch_budget_evidence"]["status"] != "matched":
            raise ValueError("新版报告未匹配批次预算。")
        if result["conditional_below_5ms"] is not None or result["error_budget_verified"]:
            raise ValueError("不得自动变更严格验收标志。")
        text = path.read_text(encoding="utf-8")
        if "计划完成 24 键" in text or "待完成 24 键" in text:
            raise ValueError("报告残留过期模板。")
        status["generated"].append(dict(
            key=identity[0], trial=identity[1],
            report=relative_link(path, ROOT), report_sha256=digest(path),
            analysis_sha256=digest(path.with_name("analysis.json"))))
        status_path.write_text(json.dumps(status, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"{len(status['generated'])}/{len(source['observations'])} K{identity[0]} "
              f"trial {identity[1]} -> {path.parent.name}", flush=True)
        generated += 1
        if generated >= limit:
            break
    for filename, expected in mapped.items():
        if digest(filename) != expected:
            raise ValueError(f"生成报告期间原始证据改变：{filename}")
    status.update(
        source_files_unchanged=True,
        complete=len(status["generated"]) == len(source["observations"]))
    status_path.write_text(json.dumps(status, ensure_ascii=False, indent=2), encoding="utf-8")
    rows = "".join(
        f'<tr><td>K{r["key"]}</td><td>{r["trial"]}</td><td><a href="'
        f'{html.escape(relative_link(ROOT/r["report"], output), quote=True)}">'
        '打开新版联合报告</a></td></tr>' for r in status["generated"])
    (output / "report.html").write_text(
        '<!doctype html><html lang="zh-CN"><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>新版全键联合报告索引</title><style>body{max-width:1000px;margin:30px auto;'
        'padding:0 20px;font:16px/1.7 "Microsoft YaHei",sans-serif}table{width:100%;'
        'border-collapse:collapse}td,th{padding:6px;border-bottom:1px solid #ddd;text-align:left}'
        '</style><h1>新版全键联合报告索引</h1>'
        f'<p>已生成{len(status["generated"])}份；旧报告保留、原始数据未修改。'
        '经验余量与条件性情景不等于严格验收通过。</p>'
        '<p><a href="../full_key_budget_001/report.html">全键中文误差预算汇总</a></p>'
        '<table><tr><th>按键</th><th>记录编号</th><th>报告</th></tr>'+rows+'</table></html>',
        encoding="utf-8")
    print("COMPLETE", status["complete"], flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--limit", type=int, default=14)
    args = parser.parse_args()
    refresh(args.summary, args.output, args.limit)

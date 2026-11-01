"""Read-only source verification and a sorted local evidence index; no devices."""

import argparse
from collections import Counter, defaultdict
import hashlib
import html
import json
import os
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

from latency_session import analysis_progress
from latency_budget_report import lookup
from measurement_files import ROOT, report_folder, screen_file


BASELINE = ROOT / "config/retained_source_hashes.json"
INDEX = ROOT / "measurements/资料总览.html"
RESULT = ROOT / "config/history/archive_audit.json"
LABELS = {"piano": "钢琴", "guitar": "吉他", "bianzhong": "编钟"}


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def relative(path):
    return Path(path).resolve().relative_to(ROOT).as_posix()


def anchor(path, label):
    target = Path(os.path.relpath(path, INDEX.parent)).as_posix()
    return f'<a href="{html.escape(target, quote=True)}">{html.escape(label)}</a>'


def report_links(record, kind, report):
    links = [anchor(report, "报告"), anchor(record, "原始数据")]
    screen = screen_file(record, kind)
    if screen.is_file():
        links.append(anchor(screen, "示波器原屏"))
    return " · ".join(links)


def audit():
    manifest = load(BASELINE)
    for filename, expected in manifest["sha256"].items():
        path = (ROOT / filename).resolve()
        if not path.is_relative_to(ROOT) or not path.is_file():
            raise ValueError(f"Missing retained source: {filename}")
        if digest(path) != expected:
            raise ValueError(f"Retained source hash mismatch: {filename}")
    mapping = load(ROOT / "config/latency_record_numbering.json")
    identity = {row["new"]: row for row in mapping["records"]}
    groups = defaultdict(list)
    latency_rows, video_rows = [], []
    logic_folders = set()
    for trial_json in (ROOT / "measurements/raw/latency").rglob("trial.json"):
        record = trial_json.parent
        raw = load(trial_json)
        reports = list(report_folder(record, "latency").glob(
            "scan_validation/verification_*/analysis.json"))
        if len(reports) != 1:
            raise ValueError(f"Expected one retained joint report: {record}")
        result = load(reports[0])
        link = load(record / "joint_capture.json")
        csv = (record / link["digital_csv"]).resolve()
        if digest(csv) != result["logic_csv_sha256"]:
            raise ValueError(f"Joint CSV association mismatch: {record}")
        logic_folders.add(csv.parent)
        for ch in ("CH1", "CH2"):
            if digest(record / f"ch{ch[-1]}.bin") != result["raw_sha256"][ch]:
                raise ValueError(f"Joint waveform association mismatch: {record}")
        report = reports[0].with_name("report.html")
        delay = (result["audio_latest_scope_s"] - result["b_window_scope_s"][0]) * 1000
        row = dict(instrument=raw["instrument_user_reported"], key=raw["key"],
                   delay_ms=delay, raw=record, report=report,
                   original_trial=raw["trial"])
        if record.name.endswith("_video_test"):
            row["number"] = "1（视频）"
            video_rows.append(row)
        else:
            if relative(record) not in identity:
                raise ValueError(f"Unmapped historical trial: {record}")
            row["number"] = identity[relative(record)]["number"]
            groups[(row["instrument"], row["key"])].append(row)
            latency_rows.append(row)
    expected = {("piano", key) for key in range(1, 25)}
    expected |= {("guitar", key) for key in (1, 12, 24)}
    expected |= {("bianzhong", key) for key in (1, 14, 24)}
    if set(groups) != expected or len(video_rows) != 1:
        raise ValueError("Historical or video coverage changed")
    for group in groups.values():
        if sorted(row["number"] for row in group) != [1, 2, 3]:
            raise ValueError("Historical numbering must be 1, 2, 3")
        check = analysis_progress(group[0]["raw"].parent, {
            "instrument_user_reported": group[0]["instrument"]}, joint=True)
        if check["usable"] != [1, 2, 3] or check["pending"]:
            raise ValueError(f"Unusable normalized group: {group[0]['raw']}")
        if group[0]["instrument"] == "piano":
            for row in group:
                path = next(report_folder(row["raw"], "latency").glob(
                    "scan_validation/verification_*/analysis.json"))
                if lookup(row["raw"], load(path))["status"] != "matched":
                    raise ValueError(f"Historical phase budget unmatched: {row['raw']}")
    actual_logic = {p.resolve() for p in (ROOT / "measurements/raw/logic").iterdir()
                    if p.is_dir()}
    if logic_folders != actual_logic:
        raise ValueError("Orphan or missing logic capture")
    sections = ['<!doctype html><html lang="zh-CN"><meta charset="utf-8">'
                '<meta name="viewport" content="width=device-width,initial-scale=1">'
                '<title>测量资料总览</title><style>'
                'body{font:16px/1.7 "Microsoft YaHei",sans-serif;max-width:1150px;margin:28px auto;'
                'padding:0 16px;color:#222}table{border-collapse:collapse;width:100%}'
                'td,th{padding:7px;border-bottom:1px solid #ddd;text-align:left}'
                'a{color:#006d75}h1{font-size:26px}h2{font-size:20px}'
                '.table{overflow-x:auto}td{white-space:nowrap}</style>'
                '<h1>测量资料总览</h1><p>顺序：复音、LRCK、钢琴、吉他、编钟。'
                '历史延迟每键保留3次，视频记录单列；原始采集试次编号仅用于追溯。'
                '分析可用不等于完整计量预算下验收通过。</p>']
    capture_counts = {}
    for kind, title in (("polyphony", "复音"), ("lrck", "LRCK采样率")):
        rows = []
        captures = list((ROOT / f"measurements/raw/{kind}").rglob("capture.json"))
        capture_counts[kind] = len(captures)
        captures.sort(key=lambda p: ("_video_test" in p.parent.name, p.parent.name))
        for capture in captures:
            raw = load(capture)
            record = capture.parent
            report = report_folder(record, kind) / "report.html"
            analysis = load(report.with_name("analysis.json"))
            expected_sha = (analysis["capture_sha256"] if kind == "polyphony"
                            else analysis["raw_sha256"])
            if digest(record / "raw.bin") != expected_sha:
                raise ValueError(f"Capture-report association mismatch: {record}")
            if kind == "polyphony":
                selection = raw["operator_declared_selection"]
                name = ("ALL（64声部）" if selection == 0 else
                        f"GROUP{selection}" if 1 <= selection <= 4 else
                        f"MUTE{selection-4}")
                value = (f"{analysis['spectral_check']}；"
                         f"{analysis['matched_enabled_peaks']}/{analysis['expected_peaks']}目标匹配")
            else:
                name = "LRCK"
                value = f"{analysis['measured_lrck_hz']:.6f} Hz"
            name += "（视频）" if "_video_test" in record.name else "（历史）"
            links = report_links(record, kind, report)
            comparison = report.with_name("comparison.html")
            if comparison.is_file():
                links += " · " + anchor(comparison, "ALL/MUTE对比")
            rows.append(f"<tr><td>{html.escape(name)}</td><td>{value}</td><td>{links}</td></tr>")
        sections.append(f"<h2>{title}</h2><div class='table'><table>"
                        "<tr><th>项目</th><th>结果</th><th>文件</th></tr>"
                        + "".join(rows) + "</table></div>")
    sections.append("<h2>视频按键延迟</h2>")
    for row in video_rows:
        sections.append(f"<p>K{row['key']}；{row['delay_ms']:.6f} ms（观察值，非完整预算验收上界）；"
                        + report_links(row["raw"], "latency", row["report"]) + "</p>")
    for instrument in ("piano", "guitar", "bianzhong"):
        rows = []
        for row in sorted((r for r in latency_rows if r["instrument"] == instrument),
                          key=lambda r: (r["key"], r["number"])):
            links = report_links(row["raw"], "latency", row["report"])
            rows.append(f"<tr><td>K{row['key']:02}</td><td>{row['number']}</td>"
                        f"<td>{row['original_trial']}</td><td>{row['delay_ms']:.6f}</td>"
                        f"<td>{links}</td></tr>")
        sections.append(f"<h2>{LABELS[instrument]}延迟</h2><div class='table'><table>"
                        "<tr><th>按键</th><th>归档编号</th><th>原采集编号</th>"
                        "<th>B扫描起点至最晚起音/ms</th><th>文件</th></tr>"
                        + "".join(rows) + "</table></div>")
    sections.append("</html>")
    INDEX.write_text("".join(sections), encoding="utf-8")
    broken = []
    for path in [INDEX, *(ROOT / "measurements/reports").rglob("*.html")]:
        for link in re.findall(r"(?:href|src)=[\"']([^\"']+)", path.read_text(encoding="utf-8-sig")):
            parsed = urlsplit(html.unescape(link))
            if parsed.scheme or not parsed.path:
                continue
            if not (path.parent / unquote(parsed.path)).exists():
                broken.append(dict(page=relative(path), link=link))
    if broken:
        raise ValueError(f"Broken local HTML links: {broken[:5]}")
    result = dict(status="complete", device_access=False,
                  immutable_sources_verified=len(manifest["sha256"]),
                  historical_latency=dict(Counter(r["instrument"] for r in latency_rows)),
                  video_latency=len(video_rows), captures=capture_counts,
                  logic_captures=len(actual_logic), all_local_html_links_verified=True)
    RESULT.parent.mkdir(parents=True, exist_ok=True)
    RESULT.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    argparse.ArgumentParser(description=__doc__).parse_args()
    audit()

"""Explicit opt-in joint acquisition; reuse the STOP-only scope downloader."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from acceptance_extra_pages import next_folder
import latency_session as session
from logic_automation import acquire
from measurement_files import directory, relative_link, report_folder


def scope_failure_message(trial, logic):
    trial = Path(trial)
    reason = "下载进程异常退出，未取得具体原因；请查看运行日志。"
    try:
        manifest = json.loads((trial / "trial.json").read_text(encoding="utf-8"))
        reason = manifest.get("error_message") or manifest.get("error") or reason
    except (OSError, ValueError, AttributeError):
        pass
    return (f"示波器保存失败：{reason}；本次示波器记录目录：{trial}；"
            f"逻辑原始记录已保留：{logic}。不完整记录不计入有效次数。")


def validate_saved(trial, csv_path, rate, margin_us, clock_ppm):
    """Validation errors must not turn a completed capture into a save failure."""
    try:
        print("LATENCY processing", flush=True)
        if not margin_us or not clock_ppm:
            from scan_latency_validation import generate_observation
            report = generate_observation(trial, csv_path, rate)
            print("Latency report: " + str(report), flush=True)
            print("误差预算尚未核实：已保存联合观察结果，不判定 5 ms 达标。", flush=True)
        else:
            from scan_latency_validation import generate
            report = generate(trial, csv_path, ("Time [s]", "Channel 0", "Channel 1", "Channel 2"),
                              margin_us, clock_ppm, True, rate)
            print("Latency report: " + str(report), flush=True)
    except Exception as error:
        diagnostic = {
            "capture_status": "complete", "validation_status": "error",
            "stage": "联合数据分析与扫描验证", "reason": f"{type(error).__name__}: {error}",
            "conclusion": "原始数据已保存；联合验证未通过，不能判定延迟小于 5 ms。",
        }
        if getattr(error, "details", None):
            diagnostic["error_details"] = error.details
            diagnostic["action"] = error.details.get("action")
        if getattr(error, "analysis_attempts", None):
            diagnostic["automatic_analysis_attempts"] = error.analysis_attempts
        if getattr(error, "initial_analysis_error", None):
            diagnostic["initial_analysis_error"] = error.initial_analysis_error
        try:
            from scan_signal_diagnostics import generate as diagnose
            report, stats = diagnose(
                trial, csv_path, ("Time [s]", "Channel 0", "Channel 1", "Channel 2"),
                diagnostic["reason"], rate, error_details=diagnostic.get("error_details"))
            diagnostic["signal_report"] = str(report)
            summaries = []
            for label, channel in zip(("A 行", "B 行"), stats["channels"]):
                period = channel["long_pulse_period_us"]
                timing = ("不足两个主脉冲" if period is None else
                          f"主脉冲周期 {period[0]:.3f}～{period[2]:.3f} µs")
                summaries.append(
                    f'{label}：{timing}，不足 1 µs 的短低脉冲 {channel["low_pulses_under_1us"]} 个')
            summaries.insert(0, "以下为完整逻辑记录的总数，不是违反边界规则的脉冲数量：")
            diagnostic["signal_summary"] = "\n".join(summaries)
        except Exception as diagnostic_error:
            diagnostic["signal_diagnostics_error"] = str(diagnostic_error)
        try:
            output = report_folder(trial, "latency") / "joint_validation_error.json"
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(diagnostic, ensure_ascii=False, indent=2), encoding="utf-8")
            diagnostic["diagnostic_file"] = str(output)
        except OSError as save_error:
            diagnostic["diagnostic_save_error"] = str(save_error)
        print("JOINT_VALIDATION_WARNING " + json.dumps(diagnostic, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--logic-rate", type=int, default=24_000_000)
    parser.add_argument("--analysis-margin-us", type=float, required=True)
    parser.add_argument("--clock-ppm", type=float, required=True)
    args, scope_args = parser.parse_known_args()
    original = argparse.ArgumentParser()
    for name in ("ip", "bitstream", "expected-sha256", "key", "trial", "force",
                 "instrument", "volume", "effects"):
        original.add_argument("--" + name, required=True)
    values = original.parse_args(scope_args)
    version = session.describe_version(values.bitstream)
    if version["sha256"] != values.expected_sha256.upper():
        raise RuntimeError("固件文件已变化，请重新建立计划。")
    import math
    if not all(math.isfinite(v) and v >= 0 for v in (args.analysis_margin_us, args.clock_ppm)):
        raise ValueError("误差预算须为有限非负数；零表示未核实，不作达标判定。")
    key, trial_number = int(values.key), int(values.trial)
    if not 1 <= key <= 24 or trial_number < 1 or values.force not in ("soft", "medium", "hard"):
        raise ValueError("按键、次数或力度无效。")
    trial = session.image_folder(version["sha256"], values.instrument) / f"K{key:02}" / values.force / f"trial_{trial_number:03}"
    if trial.exists():
        raise FileExistsError("本次记录已存在，拒绝覆盖。")
    from scope_preflight import inspect_scope
    check = inspect_scope(values.ip, "latency_joint")
    if check.errors:
        raise RuntimeError(check.text())
    logic = next_folder(directory("raw", "logic"), "logic")
    print("逻辑原始记录目录：" + str(logic), flush=True)
    csv_path = acquire(values.ip, logic, rate=args.logic_rate,
                       notify=lambda line: print(line, flush=True))
    command = [sys.executable, "-u", str(session.ROOT / "tools/capture_key_trial.py"),
               *scope_args, "--joint-analysis"]
    completed = subprocess.run(command, env=dict(os.environ, PYTHONUTF8="1"), check=False)
    if completed.returncode:
        raise RuntimeError(scope_failure_message(trial, logic))
    link = dict(path_base="trial_directory",
                logic_capture_folder=relative_link(logic, trial), digital_csv=relative_link(csv_path, trial),
                digital_sample_rate_hz=args.logic_rate,
                same_press_user_confirmed=True)
    (trial / "joint_capture.json").write_text(json.dumps(link, ensure_ascii=False, indent=2), encoding="utf-8")
    validate_saved(trial, csv_path, args.logic_rate, args.analysis_margin_us, args.clock_ppm)


if __name__ == "__main__":
    main()

"""Empirical integer-phase budget for representative timbre observations."""

import argparse
import json
from pathlib import Path
import sys

import numpy as np

from evaluate_joint_error_budget import (
    full_phase_filter, phase_onsets, rounded_allowance_us, conditional_budget_ms, SOURCES,
)
from latency_waveforms import load
from summarize_joint_latency import digest, render_html


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    summary = json.loads(args.summary.read_text(encoding="utf-8"))
    if summary["engine_sha256"] != digest(
            Path(__file__).with_name("scan_latency_validation.py")):
        raise ValueError("Analysis engine changed since replay.")
    hashes = summary["source_sha256"]
    for name, expected in hashes.items():
        if digest(name) != expected:
            raise ValueError(f"Changed evidence: {name}")
    args.output.mkdir(parents=True, exist_ok=False)
    records = []
    for old in summary["records"]:
        if old["status"] != "available_observation":
            continue
        channels, dt, evidence = load(Path(old["trial"]))
        archive, groups = {}, []
        for method in ("polyphase", "block_mean"):
            for rate in (25000, 50000, 100000):
                factor = round(1 / (rate * dt))
                filtered, offset, reference_error = full_phase_filter(channels[1], factor, method)
                for row in phase_onsets(filtered, factor, dt,
                                        old["first_column_contact_scope_s"], offset):
                    times = row["onsets"]
                    archive[f"{method}_{rate}_{int(row['threshold_mV'])}"] = times
                    groups.append(dict(
                        method=method, rate_Hz=rate, threshold_mV=row["threshold_mV"],
                        phases=factor, max_onset_s=float(times.max()),
                        min_onset_s=float(times.min()), latest_phase=int(times.argmax()),
                        reference_max_difference_V=reference_error))
                del filtered
        latest = max(row["max_onset_s"] for row in groups)
        record = dict(
            timbre=old["timbre"], key=old["key"], trial=old["trial_number"],
            trial_directory=old["trial"], original_delay_ms=old["b_to_latest_audio_ms"],
            original_envelope_ms=old["unbudgeted_envelope_ms"],
            phase_increment_us=max(0., (latest-old["audio_latest_scope_s"])*1e6),
            evaluations=sum(row["phases"] for row in groups), groups=groups,
            source_sha256=old["source_sha256"], raw_sha256=evidence["raw_sha256"])
        records.append(record)
        prefix = f"{old['timbre']}_K{old['key']:02}_trial_{old['trial_number']:03}"
        np.savez_compressed(args.output / f"{prefix}_phases.npz", **archive)
        (args.output / f"{prefix}.json").write_text(
            json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
        print(prefix, f"+{record['phase_increment_us']:.6f} us", flush=True)
        del channels
    allowance = rounded_allowance_us([r["phase_increment_us"] for r in records])
    for r in records:
        r["conditional_scenarios_ms"] = {
            str(year): conditional_budget_ms(r["original_envelope_ms"], allowance, year)
            for year in (0, 10)}
        r["phase_specific_envelope_ms"] = conditional_budget_ms(
            r["original_envelope_ms"], r["phase_increment_us"], 0)
    by_timbre = {}
    for tone in sorted({r["timbre"] for r in records}):
        group = [r for r in records if r["timbre"] == tone]
        tone_allowance = rounded_allowance_us([r["phase_increment_us"] for r in group])
        by_timbre[tone] = dict(
            count=len(group), empirical_allowance_us=tone_allowance,
            max_phase_specific_envelope_ms=max(r["phase_specific_envelope_ms"] for r in group),
            max_timbre_uniform_envelope_ms=max(conditional_budget_ms(
                r["original_envelope_ms"], tone_allowance, 0) for r in group))
    for name, expected in hashes.items():
        if digest(name) != expected:
            raise ValueError(f"Evidence changed during analysis: {name}")
    result = dict(
        kind="representative_timbre_empirical_budget", input_summary_sha256=digest(args.summary),
        analysis_engine_sha256=summary["engine_sha256"],
        count=len(records), source_sha256=hashes, source_files_unchanged=True,
        integer_phase_sweep_complete=True, continuous_phase_sweep_complete=False,
        uniform_empirical_allowance_us=allowance,
        scope_assumed_base_ppm=25, scope_official_typical_base_ppm=15,
        scope_aging_ppm_per_year=5, channel_skew_max_ns=2,
        warmup_temperature_verified=False, calibration_age_years=None,
        strict_metrological_upper_bound=False, error_budget_verified=False,
        conditional_below_5ms=None, sources=SOURCES, observations=records, timbres=by_timbre,
        max_conditional_scenarios_ms={
            str(year): max(r["conditional_scenarios_ms"][str(year)] for r in records)
            for year in (0, 10)})
    labels = {"guitar": "吉他", "bianzhong": "编钟", "bell": "历史 bell"}
    lines = ["# 新增音色：相位复核与条件性余量", "",
             f"共{len(records)}次可用记录，"
             f"{sum(r['evaluations'] for r in records):,}组整数相位/阈值复核；"
             "两种滤波方法、25/50/100kHz、10/15/20mV，枚举全部整数原始采样相位。",
             f"最大新增正向偏移{max(r['phase_increment_us'] for r in records):.6f}µs，"
             f"向上取整至10µs得到本批统一经验余量{allowance:.0f}µs。"
             "独立从新音色数据计算，没有沿用钢琴批次结果。",
             "此新增偏移是重采样相位、波形形状与连续0.1ms超阈值规则的联合敏感性，"
             "不是滤波器在硬件中额外引入的真实等待时间，也不能直接认定FPGA延迟抖动。",
             "E是扫描间隙、同步残差、采样及边界项的既有包络；"
             "U(Y)=[E+A/1000+0.000002]/[1-(25+5Y)×10⁻⁶]，单位ms。",
             "25ppm为计算假设，并非官方保证上限。存档官方手册15ppm带典型值注释，"
             "另有5ppm/年漂移及2ns通道偏差；本机预热、温度、校准日期未核实。"
             "本批整数相位检查不能替代连续时间及计量校准，结论仍为条件性结果。", "",
             "|音色|按键|可用次数|最大观测/ms|最大新增偏移/µs|基础时基假设包络/ms|另加10年漂移情景/ms|",
             "|---|---|---|---|---|---|---|"]
    for tone, key in sorted({(r["timbre"], r["key"]) for r in records}):
        group = [r for r in records if (r["timbre"], r["key"]) == (tone, key)]
        lines.append(
            f"|{labels[tone]}|K{key}|{len(group)}|"
            f"{max(r['original_delay_ms'] for r in group):.6f}|"
            f"{max(r['phase_increment_us'] for r in group):.6f}|"
            f"{max(r['conditional_scenarios_ms']['0'] for r in group):.6f}|"
            f"{max(r['conditional_scenarios_ms']['10'] for r in group):.6f}|")
    lines += ["", "## 按音色区分", ""]
    for tone, row in by_timbre.items():
        lines.append(
            f"- {labels[tone]}：{row['count']}条，独立批次经验余量"
            f"{row['empirical_allowance_us']:.0f}µs；"
            f"按该音色统一余量计算的最大包络{row['max_timbre_uniform_envelope_ms']:.6f}ms；"
            f"不交叉叠加不同记录极值、仅逐条计入自身全部相位偏移的最大包络"
            f"{row['max_phase_specific_envelope_ms']:.6f}ms。")
    lines += ["", "统一余量表比逐条相位包络更保守，两者都不是计量保证上限。"
              "即使逐条计入，若超过5ms，也不能报告为小于5ms已获证明；"
              "这同样不等于已证实真实物理闭合延迟超过5ms。",
              "上述为代表键的实测结果，不是全键、全音色、全部力度最坏情况证明。"
              "不把失败记录归为通过，也不因是否小于5ms改变算法或余量。"]
    (args.output / "summary.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    (args.output / "summary.md").write_text("\n".join(lines), encoding="utf-8")
    (args.output / "report.html").write_text(render_html(lines), encoding="utf-8")
    print("FINAL", allowance, result["max_conditional_scenarios_ms"], flush=True)


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    main()

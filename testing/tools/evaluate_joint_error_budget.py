"""Offline, all-integer-phase onset sensitivity and conditional budget report."""

import argparse
import csv
import hashlib
import inspect
import json
import math
from pathlib import Path
import sys

import numpy as np
import scipy
from scipy.signal import firwin, oaconvolve, resample_poly

from summarize_joint_latency import digest, render_html


THRESHOLD_EPSILON_V = 1e-9
SOURCES = [
    {
        "title": "RIGOL MSO/DS2000A官方英文数据手册，第6及11页",
        "url": "https://download.rigol.com/en/Manual/Digital%20Oscilloscope/"
               "MSO%26DS2000A/MSO2000A%26DS2000A_Datasheet_EN.pdf",
        "base_ppm": 15, "aging_ppm_per_year": 5, "channel_skew_max_ns": 2,
        "base_accuracy_is_typical": True,
        "selection": "时基精度带注[1]，第11页明确为典型值。25 ppm仅为"
                     "高于官方典型值的保守计算假设，非官方保证值或校准上限。",
        "conditions": "规定工作温度，连续运行超过30分钟；本机校准、预热及温度记录未核实。",
    },
]


def full_phase_filter(signal, factor, method):
    """Retain the full source; vary the output grid, not the input boundary."""
    if factor < 2:
        raise ValueError("降采样因子必须至少为2。")
    if method == "polyphase":
        half = 10 * factor
        taps = firwin(2 * half + 1, 1.0 / factor, window=("kaiser", 5.0))
        filtered = oaconvolve(signal, taps, mode="same")
        reference = resample_poly(signal, 1, factor)
        error = float(np.max(np.abs(filtered[::factor] - reference)))
        if error > THRESHOLD_EPSILON_V / 10:
            raise ValueError(f"全网格FIR与原resample_poly不一致：{error:g} V")
        return filtered, 0.0, error
    if method == "block_mean":
        sums = np.concatenate(([0.0], np.cumsum(signal, dtype=np.float64)))
        filtered = (sums[factor:] - sums[:-factor]) / factor
        reference = signal[:len(signal) // factor * factor].reshape(-1, factor).mean(1)
        error = float(np.max(np.abs(filtered[::factor] - reference)))
        if error > THRESHOLD_EPSILON_V / 10:
            raise ValueError(f"滑动均值与原分块均值不一致：{error:g} V")
        return filtered, (factor - 1) / 2, error
    raise ValueError(method)


def phase_onsets(filtered, factor, dt, first_contact, sample_offset):
    """Vectorized columns enumerate every integer source-sample grid phase."""
    complete = len(filtered) // factor
    values = filtered[:complete * factor].reshape(complete, factor)
    grid = np.arange(complete, dtype=np.int64)[:, None] * factor
    phase = np.arange(factor, dtype=np.int64)[None, :]
    low = max(0, math.floor(((first_contact - .0035) / dt - sample_offset) / factor))
    high = min(complete, math.ceil(
        ((first_contact - .0005) / dt - sample_offset) / factor) + 1)
    baseline_t = (grid[low:high] + phase + sample_offset) * dt
    mask = (baseline_t > first_contact - .0035) & (
        baseline_t < first_contact - .0005)
    if not np.all(mask.sum(axis=0) >= 10):
        raise ValueError("至少一个相位的按下前静音基线不足。")
    centers = np.nanmedian(np.where(mask, values[low:high], np.nan), axis=0)
    start = max(0, math.floor((first_contact / dt - sample_offset) / factor))
    search = values[start:]
    time = (grid[start:] + phase + sample_offset) * dt
    length = math.ceil(.0001 / (factor * dt))
    if len(search) < length:
        raise ValueError("起音确认数据不足。")
    rows = []
    for threshold in (.010, .015, .020):
        # Equal-to-threshold samples are conservatively below, with a 1 nV
        # numerical guard shared across the independent reference checks.
        above = (abs(search - centers) > threshold + THRESHOLD_EPSILON_V) & (
            time > first_contact)
        count = len(above) - length + 1
        hits = above[:count].copy()
        for offset in range(1, length):
            hits &= above[offset:offset + count]
        valid = hits.any(axis=0)
        if not valid.all():
            raise ValueError(
                f"{threshold*1000:g} mV 有 {(~valid).sum()} 个相位无完整起音。")
        indices = hits.argmax(axis=0) + start
        times = (indices * factor + np.arange(factor) + sample_offset) * dt
        rows.append(dict(threshold_mV=threshold * 1000, onsets=times,
                         baseline_centers=centers))
    return rows


def rounded_allowance_us(increments):
    if not increments or not np.isfinite(increments).all():
        raise ValueError("新增相位偏移无效。")
    return float(math.ceil(max(0.0, max(increments)) / 10) * 10)


def conditional_budget_ms(envelope_ms, allowance_us, years):
    if not all(math.isfinite(v) and v >= 0 for v in (
            envelope_ms, allowance_us, years)):
        raise ValueError("预算参数必须为有限非负数。")
    fraction = (25 + 5 * years) * 1e-6
    if fraction >= 1:
        raise ValueError("时钟相对误差不能达到或超过1。")
    return (envelope_ms + allowance_us / 1000 + .000002) / (1 - fraction)


def report(summary, observations, allowance, output):
    key_rows = []
    for key in range(1, 25):
        group = [r for r in observations if r["key"] == key]
        if len(group) < 3:
            raise ValueError(f"K{key}不足3次。")
        key_rows.append(dict(
            key=key, count=len(group),
            max_delay_ms=max(r["original_delay_ms"] for r in group),
            max_envelope_ms=max(r["original_envelope_ms"] for r in group),
            max_phase_increment_us=max(r["phase_increment_us"] for r in group),
            conditional_base_ms=max(r["conditional_scenarios_ms"]["0"] for r in group),
            conditional_10_year_ms=max(r["conditional_scenarios_ms"]["10"] for r in group),
        ))
    worst = max(observations, key=lambda r: r["conditional_scenarios_ms"]["0"])
    result = dict(
        kind="empirical_conditional_error_budget", device_access=False,
        input_summary_sha256=summary["input_sha256"],
        source_sha256=summary["source_sha256"],
        analysis_engine_sha256=summary["engine_sha256"],
        source_files_unchanged=True, count=len(observations), keys=key_rows,
        observations=observations, sources=SOURCES,
        integer_phase_sweep_complete=True, continuous_phase_sweep_complete=False,
        uniform_empirical_allowance_us=allowance,
        allowance_policy="84次每条最大正向新增偏移的最大值向上取整到10 µs；"
                         "不重复加入原18项极差；非校准确认的系统误差上限。",
        threshold_numerical_guard_V=THRESHOLD_EPSILON_V,
        scope_assumed_base_ppm=25, scope_official_typical_base_ppm=15,
        scope_aging_ppm_per_year=5,
        channel_skew_max_ns=2,
        warmup_temperature_verified=False, calibration_age_years=None,
        strict_metrological_upper_bound=False, error_budget_verified=False,
        conditional_below_5ms=None,
        empirical_scenarios_below_5ms={
            str(y): all(r["conditional_scenarios_ms"][str(y)] < 5
                        for r in observations) for y in (0, 5, 10, 20)},
        max_conditional_scenarios_ms={
            str(y): max(r["conditional_scenarios_ms"][str(y)]
                        for r in observations) for y in (0, 5, 10, 20)},
        worst_record=dict(key=worst["key"], trial=worst["trial"]),
        runtime=dict(numpy=np.__version__, scipy=scipy.__version__,
                     resample_poly_source_sha256=hashlib.sha256(
                         inspect.getsource(resample_poly).encode()).hexdigest()),
    )
    lines = [
        "# 24键延迟：相位复核与条件性误差预算", "",
        "## 结果", "",
        f"- 全部{len(observations)}次可用记录均纳入，24键各至少3次。",
        "- 原始数据和旧报告不改动，所有审计源文件在补算前后均经SHA-256核对。",
        f"- 原最大扫描等余量包络：{max(r['original_envelope_ms'] for r in observations):.6f} ms。",
        f"- 全批次新增相位偏移最大值：{max(r['phase_increment_us'] for r in observations):.6f} µs。",
        f"- 统一额外经验分析余量：{allowance:.0f} µs（上述最大值向上取整到10 µs）。",
        f"- 按25 ppm时基假设、2 ns通道偏差计算，最大条件性包络："
        f"{result['max_conditional_scenarios_ms']['0']:.6f} ms。",
        f"- 若另按距校准10年累计漂移情景计算："
        f"{result['max_conditional_scenarios_ms']['10']:.6f} ms；这不是本机真实校准年龄。",
        f"- 最大值对应K{worst['key']}第{worst['trial']}次。",
        "- 上述为经验分析余量及仪器规格条件成立时的条件性结果，不是校准确认的严格物理闭合延迟上界。",
        "", "## 计算口径", "",
        "每条条件性包络 U(Y) = [E + A/1000 + 0.000002] / "
        "[1 - (25 + 5Y)×10⁻⁶]，单位ms。",
        "E为旧包络（已包含扫描等待、对齐残差、采样及边界余量），A为本批统一经验分析余量（µs），"
        "Y为距适用校准基准的年数；0.000002 ms为2 ns通道间最大偏差。"
        "用整个包络计算时基项，不仅对3.5 ms图示间隔计算，也不重复添加扫描等待。",
        "已下载核实的RIGOL官方英文手册第6页为15 ppm、5 ppm/年；"
        "时基精度带注[1]，第11页明确[1]为典型值，不是保证上限。"
        "本报告25 ppm是大于15 ppm的保守计算假设，不能由此反推本机真实误差必小于25 ppm。"
        "先前提及的中文25 ppm资料未能成功下载核实，因此不作为本次正式规格依据。"
        "规格要求规定温度下连续运行超过30分钟，本批未记录温度、预热及实际校准日期。",
        "", "## 全键结果", "",
        "|按键|可用次数|原最大间隔/ms|原最大包络/ms|最大新增相位偏移/µs|条件性包络：基础25 ppm/ms|条件性包络：加10年漂移/ms|",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for row in key_rows:
        lines.append(f"|K{row['key']}|{row['count']}|{row['max_delay_ms']:.6f}|"
                     f"{row['max_envelope_ms']:.6f}|{row['max_phase_increment_us']:.3f}|"
                     f"{row['conditional_base_ms']:.6f}|{row['conditional_10_year_ms']:.6f}|")
    lines += [
        "", "## 相位复核方法", "",
        "两种方法×25/50/100 kHz×10/15/20 mV；每个降采样因子f检查0到f−1全部整数原始采样相位。"
        "FIR为与原SciPy默认resample_poly相同的Kaiser(β=5)、20f+1抽头低通；"
        "原始输入边界固定，不裁掉相位起点之前的样本。"
        "分块均值保留每块中心时刻；以完整输入的滑动均值枚举所有分块起点。",
        "每个相位独立按原始规则估计静音基线，并寻找连续至少0.1 ms超阈值的首个起音。"
        "FIR全网格零相位与原resample_poly逐点比对，分块均值零相位与原reshape均值逐点比对；"
        "超过0.1 nV数值差异即中止。阈值比较另使用1 nV数值保护带，等于阈值按未超过处理，"
        "这不是新增的模拟电压准确度声明。",
        "每条新增偏移=max(0，所有新增相位的最晚起音−旧18项最晚起音)。"
        "统一余量从全部记录的最大新增偏移得到，不因按键或结果是否小于5 ms选择算法。"
        "旧18项中位约50 µs、最大约80 µs的极差已由旧最晚起音覆盖，不重复相加。"
        "FIR未来样本支持长度不是额外测量误差，不能直接再加。",
        "", "## 结论及仍需确认的条件", "",
        "本轮钢琴音色、音量127、音效关闭、中等力度的84次记录，"
        "在采用本批经验分析余量及上述仪器规格假设时，条件性包络均小于5 ms。",
        "整数相位检查覆盖记录中的原始采样网格，不等同于连续时间校准。"
        "经验余量只约束本批被比较的方法及相位，不能证明所有滤波方法共有的系统偏移为零，"
        "也不包含独立探头/线缆校准或电压阈值到真实物理声学起音的转换。",
        "起点仍是B触点持续有效导通的扫描约束，不是任意首次机械接触；"
        "使用前一B窗口起点覆盖扫描盲区，以相邻扫描间的有效持续导通假设为条件。"
        "不能覆盖扫描期间完全不可见的短暂导通或任意接触抖动历史。",
        "正式文档可采用本报告的条件性结论，但必须保留测量条件、起终点定义、"
        "经验余量口径及仪器假设。典型值不能冒充保证值；若需要校准确认的严格上界，"
        "还需本机有效校准依据，不能靠软件补算取代。"
        "未核实的预热/温度/校准日期不能填成已确认；因此软件严格验收标志仍不自动改为通过。",
        "", "## 官方资料", "",
    ]
    for source in SOURCES:
        lines += [source["title"], source["url"]]
    output.mkdir(exist_ok=True, parents=True)
    (output / "summary.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    (output / "report.md").write_text("\n".join(lines), encoding="utf-8")
    (output / "report.html").write_text(render_html(lines), encoding="utf-8")
    with (output / "keys.csv").open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["按键", "次数", "原最大间隔/ms", "原最大包络/ms",
                         "最大新增相位偏移/µs", "基础时基条件性包络/ms",
                         "10年漂移情景条件性包络/ms"])
        for row in key_rows:
            writer.writerow([f"K{row['key']}", *[row[k] for k in (
                "count", "max_delay_ms", "max_envelope_ms", "max_phase_increment_us",
                "conditional_base_ms", "conditional_10_year_ms")]])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("summary", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    if args.output.exists() and not args.resume:
        raise FileExistsError(args.output)
    app = args.app.resolve()
    sys.path.insert(0, str(app / "tools"))
    from latency_waveforms import load
    summary = json.loads(args.summary.read_text(encoding="utf-8"))
    summary["input_sha256"] = digest(args.summary)
    if digest(app / "tools/scan_latency_validation.py") != summary["engine_sha256"]:
        raise ValueError("全批次审计后分析引擎已改变。")
    for filename, expected in summary["source_sha256"].items():
        if digest(filename) != expected:
            raise ValueError(f"原始证据已改变：{filename}")
    by_trial = {}
    for filename in summary["source_sha256"]:
        path = Path(filename)
        if path.name == "trial.json":
            data = json.loads(path.read_text(encoding="utf-8"))
            by_trial[(data["key"], data["trial"])] = path.parent
    if len(summary["observations"]) != 84:
        raise ValueError("本轮应有84次已审计可用记录。")
    args.output.mkdir(parents=True, exist_ok=args.resume)
    observations = []
    for index, old in enumerate(summary["observations"], 1):
        trial = by_trial[(old["key"], old["trial"])]
        prefix = f"K{old['key']:02d}_trial_{old['trial']:03d}"
        saved = args.output / f"{prefix}.json"
        if args.resume and saved.exists():
            result = json.loads(saved.read_text(encoding="utf-8"))
            archive_path = args.output / f"{prefix}_phases.npz"
            with np.load(archive_path) as archive:
                latest = max(float(archive[name].max()) for name in archive.files)
            if (result["key"] != old["key"] or result["trial"] != old["trial"]
                    or result["original_delay_ms"] != old["delay_ms"]
                    or result["original_envelope_ms"] != old["envelope_ms"]
                    or latest != result["phase_latest_onset_s"]):
                raise ValueError("断点结果与输入不一致。")
            for channel in ("CH1", "CH2"):
                source = trial / f"ch{channel[-1]}.bin"
                if result["raw_sha256"][channel] != summary["source_sha256"][str(source)]:
                    raise ValueError("断点原始哈希不一致。")
            observations.append(result)
            print(f"{index}/84 {prefix}: verified checkpoint", flush=True)
            continue
        channels, dt, evidence = load(trial)
        anchor = old["sensitivities"][0]
        first_contact = anchor["onset_scope_s"] - anchor["onset_from_contact_ms"] / 1000
        original_latest = max(s["onset_scope_s"] for s in old["sensitivities"])
        archive, groups = {}, []
        for mode in ("polyphase", "block_mean"):
            for rate in (25000, 50000, 100000):
                factor = max(1, round(1 / (rate * dt)))
                filtered, offset, error = full_phase_filter(channels[1], factor, mode)
                for row in phase_onsets(filtered, factor, dt, first_contact, offset):
                    times = row["onsets"]
                    name = f"{mode}_{rate}_{int(row['threshold_mV'])}"
                    archive[name] = times
                    maximum = int(np.argmax(times))
                    groups.append(dict(
                        method=mode, rate_Hz=1 / (factor * dt),
                        threshold_mV=row["threshold_mV"], phases=factor,
                        min_onset_s=float(times.min()), max_onset_s=float(times.max()),
                        latest_phase=maximum, phase_zero_onset_s=float(times[0]),
                        reference_max_difference_V=error,
                    ))
                del filtered
        latest = max(g["max_onset_s"] for g in groups)
        result = dict(
            key=old["key"], trial=old["trial"],
            original_delay_ms=old["delay_ms"], original_envelope_ms=old["envelope_ms"],
            original_latest_onset_s=original_latest, phase_latest_onset_s=latest,
            phase_increment_us=max(0.0, (latest - original_latest) * 1e6),
            scope_dt_s=dt, raw_sha256=evidence["raw_sha256"], groups=groups,
            evaluations=sum(g["phases"] for g in groups),
        )
        observations.append(result)
        np.savez_compressed(args.output / f"{prefix}_phases.npz", **archive)
        (args.output / f"{prefix}.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"{index}/84 {prefix}: +{result['phase_increment_us']:.6f} us, "
              f"{result['evaluations']} phase/threshold evaluations", flush=True)
        del channels
    allowance = rounded_allowance_us([r["phase_increment_us"] for r in observations])
    for record in observations:
        record["conditional_scenarios_ms"] = {
            str(year): conditional_budget_ms(record["original_envelope_ms"], allowance, year)
            for year in (0, 5, 10, 20)}
    for filename, expected in summary["source_sha256"].items():
        if digest(filename) != expected:
            raise ValueError(f"补算期间原始证据已改变：{filename}")
    if digest(args.summary) != summary["input_sha256"]:
        raise ValueError("补算期间输入汇总已改变。")
    result = report(summary, observations, allowance, args.output)
    (args.output / "sources.json").write_text(
        json.dumps(SOURCES, ensure_ascii=False, indent=2), encoding="utf-8")
    print("FINAL", allowance, result["max_conditional_scenarios_ms"], flush=True)


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    main()

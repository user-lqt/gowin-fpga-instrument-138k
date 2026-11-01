"""Offline diagnostic only: do not replace the production onset criterion."""

import argparse
import json
import math
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

from evaluate_joint_error_budget import full_phase_filter, phase_onsets
from latency_waveforms import load
from summarize_joint_latency import digest, render_html


def runs(mask):
    edges = np.diff(np.r_[False, mask, False].astype(np.int8))
    return np.flatnonzero(edges == 1), np.flatnonzero(edges == -1)


def sampled_detail(filtered, factor, dt, contact, phase, threshold):
    indices = np.arange(phase, len(filtered), factor, dtype=np.int64)
    times, signal = indices*dt, filtered[indices]
    base = signal[(times > contact-.0035) & (times < contact-.0005)]
    center = float(np.median(base))
    above = (abs(signal-center) > threshold+1e-9) & (times > contact)
    start, stop = runs(above)
    required = math.ceil(.0001/(factor*dt))
    qualifying = np.flatnonzero(stop-start >= required)
    if not len(qualifying):
        raise ValueError("No qualifying sampled onset")
    first = int(start[qualifying[0]])
    return dict(phase=int(phase), center_V=center,
                onset_scope_s=float(times[first]), required_samples=required,
                sampled_first_to_last_span_us=(required-1)*factor*dt*1e6,
                first_hit_sample_indices=indices[first:first+required].tolist(),
                first_hit_scope_s=times[first:first+required].tolist(),
                first_hit_mV=((signal[first:first+required]-center)*1000).tolist())


def full_grid_detail(filtered, dt, contact, center, threshold):
    """A diagnostic on this filtered grid, not an analog metrological bound."""
    above = abs(filtered-center) > threshold+1e-9
    above[:math.floor(contact/dt)+1] = False
    start, stop = runs(above)
    required = math.ceil(.0001/dt)+1
    eligible = stop-start >= required
    if not eligible.any():
        raise ValueError("No full-grid 100 us onset")
    index = int(start[eligible][0])
    return dict(onset_scope_s=index*dt, required_samples=required,
                continuous_grid_test_not_raw_analog=True,
                interval_definition="first-to-last sample time >= 100 us")


def diagnose(record, phase_record, output):
    trial = Path(record["trial"])
    channels, dt, evidence = load(trial)
    meta = json.loads((trial/"metadata.json").read_text(encoding="utf-8"))
    contact = record["first_column_contact_scope_s"]
    b = record["audio_latest_scope_s"]-record["b_to_latest_audio_ms"]/1000
    factor = round(1/(100000*dt))
    filtered, _, reference_error = full_phase_filter(channels[1], factor, "polyphase")
    phase_rows = phase_onsets(filtered, factor, dt, contact, 0)
    row = next(r for r in phase_rows if r["threshold_mV"] == 20)
    phase = int(row["onsets"].argmax())
    zero = sampled_detail(filtered, factor, dt, contact, 0, .020)
    late = sampled_detail(filtered, factor, dt, contact, phase, .020)
    assert abs(zero["onset_scope_s"]-row["onsets"][0]) < dt/2
    assert abs(late["onset_scope_s"]-row["onsets"][phase]) < dt/2
    raw_time = np.arange(len(channels[1]))*dt
    baseline = channels[1][(raw_time > contact-.0035) & (raw_time < contact-.0005)]
    center = float(np.median(baseline))
    codes, counts = np.unique(baseline, return_counts=True)
    grid = full_grid_detail(filtered, dt, contact, zero["center_V"], .020)
    # Locate threshold violations between the samples of phase zero's first hit.
    first, last = zero["first_hit_sample_indices"][0], zero["first_hit_sample_indices"][-1]
    inside = abs(filtered[first:last+1]-zero["center_V"]) <= .020+1e-9
    ns, ne = runs(inside)
    notches = [dict(start_scope_s=(first+int(s))*dt,
                    duration_us=float((e-s)*dt*1e6))
               for s, e in zip(ns, ne)]
    result = dict(
        trial=str(trial), key=12, trial_number=record["trial_number"],
        b_window_start_scope_s=b, raw_dt_s=dt,
        quantization_step_mV=float(meta["CH2"]["preamble"].split(",")[7])*1000,
        baseline_codes_mV=(codes*1000).tolist(), baseline_code_counts=counts.tolist(),
        baseline_rms_mV=float(np.std(baseline)*1000),
        raw_peak_to_peak_V=float(np.ptp(channels[1])),
        rails=evidence["rails"][1],
        phase_zero=zero, latest_phase=late, full_grid=grid,
        phase_zero_hit_contains_unobserved_below_threshold_notches=notches,
        polyphase_100k_20mV_phase_range_us=float(np.ptp(row["onsets"])*1e6),
        original_18_way_latest_delay_ms=record["b_to_latest_audio_ms"],
        latest_all_phase_delay_ms=(
            phase_record["original_delay_ms"]+phase_record["phase_increment_us"]/1000),
        reference_filter_max_difference_V=reference_error,
        source_sha256=record["source_sha256"], production_analysis_changed=False)
    prefix = f"K12_trial_{record['trial_number']:03}"
    (output/f"{prefix}.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    plt.rcParams["font.family"] = ["Microsoft YaHei"]
    plt.rcParams["axes.unicode_minus"] = False
    fig, axes = plt.subplots(3, 1, figsize=(12, 10), layout="constrained")
    x = (raw_time-b)*1000
    window = (x >= 3.1) & (x <= 5.3)
    axes[0].plot(x[window][::100], channels[1][window][::100]*1000,
                 color="#aaa", linewidth=.6, label="原始BYTE电压（绘图每100点取1点）")
    axes[0].plot(x[window][::20], (filtered[window][::20]-zero["center_V"])*1000,
                 color="#186c72", linewidth=1, label="100kHz同等FIR，保留完整原采样网格")
    axes[0].axvline((zero["onset_scope_s"]-b)*1000, color="#4169a1", label="相位0判定")
    axes[0].axvline((late["onset_scope_s"]-b)*1000, color="#b43c46", label="最晚相位判定")
    axes[0].set_ylabel("电压 / mV")
    axes[0].legend(fontsize=8, loc="upper left")
    zoom_left = first*dt-10e-6
    zoom_right = last*dt+10e-6
    select = (raw_time >= zoom_left) & (raw_time <= zoom_right)
    axes[1].plot(x[select], (filtered[select]-zero["center_V"])*1000,
                 color="#186c72", linewidth=1.2, label="完整网格滤波波形")
    axes[1].scatter((np.array(zero["first_hit_scope_s"])-b)*1000,
                    zero["first_hit_mV"], color="#4169a1", s=22, zorder=3,
                    label=f"相位0的{zero['required_samples']}个超阈值采样点")
    for notch in notches:
        axes[1].axvspan((notch["start_scope_s"]-b)*1000,
                       (notch["start_scope_s"]+notch["duration_us"]*1e-6-b)*1000,
                       color="#f5bb86", alpha=.7)
    axes[1].set_ylabel("电压 / mV")
    axes[1].set_title("相位0首组有效采样点：检查点与点之间是否跌回阈值", fontsize=11)
    axes[1].legend(fontsize=8)
    axes[2].plot(np.arange(factor)*dt*1e6, (row["onsets"]-b)*1000,
                 color="#b43c46", linewidth=.9)
    axes[2].set_xlabel("100kHz重采样网格相位 / µs")
    axes[2].set_ylabel("B窗口起点到判定起音 / ms")
    axes[2].set_title("同一条原始记录，仅改变采样网格相位", fontsize=11)
    for ax in axes[:2]:
        ax.axhline(20, color="#777", linestyle="--", linewidth=.8)
        ax.axhline(-20, color="#777", linestyle="--", linewidth=.8)
        ax.set_xlabel("相对B窗口起点 / ms")
        ax.grid(alpha=.15)
    fig.suptitle(f"吉他 K12 第{record['trial_number']}条：起音判据离线核查", fontsize=15)
    fig.savefig(output/f"{prefix}.png", dpi=160)
    plt.close(fig)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("comparison", type=Path)
    parser.add_argument("budget", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    data = json.loads(args.comparison.read_text(encoding="utf-8"))
    budget = json.loads(args.budget.read_text(encoding="utf-8"))
    if budget["input_summary_sha256"] != digest(args.comparison):
        raise ValueError("Input comparison does not match phase audit")
    group = [r for r in data["records"] if r["timbre"] == "guitar"
             and r["key"] == 12 and r["status"] == "available_observation"]
    for r in group:
        for name, expected in r["source_sha256"].items():
            if digest(name) != expected:
                raise ValueError(f"Source changed: {name}")
    args.output.mkdir(parents=True, exist_ok=False)
    details = []
    for record in group:
        phase = next(r for r in budget["observations"]
                     if r["trial_directory"] == record["trial"])
        details.append(diagnose(record, phase, args.output))
        print(record["trial_number"], details[-1]["polyphase_100k_20mV_phase_range_us"],
              details[-1]["phase_zero_hit_contains_unobserved_below_threshold_notches"], flush=True)
    for r in group:
        for name, expected in r["source_sha256"].items():
            if digest(name) != expected:
                raise ValueError(f"Source changed during diagnosis: {name}")
    summary = dict(kind="diagnostic_guitar_onset", production_analysis_changed=False,
                   device_access=False, source_files_unchanged=True,
                   script_sha256=digest(__file__), details=details)
    (args.output/"summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    lines = ["# 吉他K12起音判据核查", "",
             "仅使用已有数据。不连接仪器、不改固件、不修改正式起音算法和旧报告数值。",
             "目标是解释判定敏感性，而不是选择更早算法使结果小于5ms。",
             "", "|记录|原18项最晚读数/ms|全部相位最晚读数/ms|100kHz/20mV自身相位极差/µs|原始量化步进/mV|",
             "|---|---|---|---|---|"]
    for r in details:
        lines.append(f"|{r['trial_number']}|{r['original_18_way_latest_delay_ms']:.6f}|"
                     f"{r['latest_all_phase_delay_ms']:.6f}|"
                     f"{r['polyphase_100k_20mV_phase_range_us']:.3f}|"
                     f"{r['quantization_step_mV']:.1f}|")
    lines += ["", "## 已核实的规则边界", "",
              "100kHz下原规则要求ceil(0.1ms/10µs)=10个连续超阈值采样点。"
              "首点到末点实际只跨90µs，且采样点之间是否重新跌入阈值没有逐点核对。"
              "25kHz下3点跨80µs，50kHz下5点跨80µs。"
              "因此不能把该规则不加限定地写为模拟信号连续0.1ms全程超阈值。",
              "本次额外的完整网格检查，仅验证同一FIR输出在原5ns网格上的持续性，"
              "不是对未采样的真实模拟信号作连续时间保证，也不替换正式指标。", ""]
    for r in details:
        lines += [f"## 第{r['trial_number']}条", "",
                  f"- 相位0首组{r['phase_zero']['required_samples']}点跨"
                  f"{r['phase_zero']['sampled_first_to_last_span_us']:.1f}µs，"
                  f"点间存在{len(r['phase_zero_hit_contains_unobserved_below_threshold_notches'])}"
                  "段完整网格跌回阈值区间。",
                  f"- 相同FIR完整网格按首末点跨至少100µs复核，起点相对B为"
                  f"{(r['full_grid']['onset_scope_s']-r['b_window_start_scope_s'])*1000:.6f}ms；"
                  "这不是新正式延迟结果。",
                  f"- 原始基线标准差{r['baseline_rms_mV']:.3f}mV，量化步进"
                  f"{r['quantization_step_mV']:.1f}mV；降采样后的亚码变化依赖平均/滤波，"
                  "不能等同于原始单点已有相同电压分辨率。"]
    lines += ["", "## 后续", "",
              "先不要重复整轮采集。应先统一报告中离散点确认与连续时间确认的口径，"
              "再用钢琴、吉他、编钟全部已有可用数据回放候选判据。"
              "若改用能量/RMS包络，必须标注为不同指标，阈值和确认规则统一，不能挑早值。"
              "原始量化步进与阈值同量级，需要后续独立核查电压分辨率、静音噪声与起音证据；"
              "不能仅凭0.65ms相位敏感性断言硬件本身抖动。"]
    (args.output/"summary.md").write_text("\n".join(lines), encoding="utf-8")
    page = render_html(lines)
    pictures = "".join(f'<h2>第{r["trial_number"]}条原始数据诊断</h2>'
                       f'<img style="max-width:100%" src="K12_trial_{r["trial_number"]:03}.png">'
                       for r in details)
    (args.output/"report.html").write_text(page.replace("</html>", pictures+"</html>"),
                                           encoding="utf-8")


if __name__ == "__main__":
    main()

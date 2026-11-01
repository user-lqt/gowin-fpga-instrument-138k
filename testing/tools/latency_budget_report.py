"""Render registered empirical budgets without changing measurement verdicts."""

import hashlib
import html
import json
import math
from pathlib import Path

from measurement_files import ROOT, relative_link


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def inside(root, relative):
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError("预算路径超出软件目录。")
    return path


def lookup(trial, result=None, root=None):
    """Match all six raw sources and the audited timing, never just key/firmware."""
    root = Path(root) if root is not None else ROOT
    trial = Path(trial).resolve()
    registry = root / "measurements/reports/latency/budget_profiles.json"
    if not registry.exists():
        return dict(status="unmatched", reason="此记录尚无已登记的批次相位复核；不自动套用其他批次余量。")
    try:
        if not trial.is_relative_to((root / "measurements/raw/latency").resolve()):
            raise ValueError("记录不在本软件延迟原始数据目录内。")
        raw = json.loads((trial / "trial.json").read_text(encoding="utf-8"))
        for profile in json.loads(registry.read_text(encoding="utf-8"))["profiles"]:
            summary_file = inside(root, profile["summary"])
            if digest(summary_file) != profile["sha256"]:
                raise ValueError("批次预算文件哈希不一致，拒绝复用。")
            budget = json.loads(summary_file.read_text(encoding="utf-8"))
            original_root = Path(profile["original_root"])
            sources = {}
            relocation_file = root / "config/latency_record_numbering.json"
            relocations = (json.loads(relocation_file.read_text(encoding="utf-8"))["paths"]
                           if relocation_file.is_file() else {})
            for filename, expected in budget["source_sha256"].items():
                relative = Path(filename).relative_to(original_root)
                for old, new in relocations.items():
                    if relative.as_posix() == old or relative.as_posix().startswith(old + "/"):
                        relative = Path(new) / relative.relative_to(old)
                        break
                sources[inside(root, relative)] = expected
            if trial / "trial.json" not in sources:
                continue
            manifest = json.loads((trial / "joint_capture.json").read_text(encoding="utf-8"))
            csv = (trial / manifest["digital_csv"]).resolve()
            if not csv.is_relative_to((root / "measurements/raw/logic").resolve()):
                raise ValueError("联合数字记录不在本软件原始数据目录内。")
            for path in [trial / name for name in (
                    "trial.json", "metadata.json", "ch1.bin", "ch2.bin",
                    "joint_capture.json")] + [csv]:
                if path not in sources or digest(path) != sources[path]:
                    raise ValueError("本记录原始证据与批次预算不一致，拒绝复用。")
            matches = [r for r in budget["observations"]
                       if r["key"] == raw["key"] and r["trial"] == raw["trial"]]
            if len(matches) != 1:
                raise ValueError("批次预算记录重复或缺失。")
            row = matches[0]
            if result is not None:
                observed = (result["audio_latest_scope_s"] -
                            result["b_window_scope_s"][0]) * 1000
                envelope = result.get("unbudgeted_timing_envelope_ms")
                if (envelope is None or not math.isfinite(observed)
                        or not math.isfinite(envelope)
                        or abs(observed - row["original_delay_ms"]) > 1e-8
                        or abs(envelope - row["original_envelope_ms"]) > 1e-8
                        or result.get("logic_csv_sha256") != sources[csv]):
                    raise ValueError("当前联合计时与已复核预算不一致，须重新相位评估。")
            allowance = budget["uniform_empirical_allowance_us"]
            ppm = budget["scope_assumed_base_ppm"]
            skew = budget["channel_skew_max_ns"]
            aging = budget["scope_aging_ppm_per_year"]
            parameters = (allowance, ppm, skew, aging, row["original_envelope_ms"])
            if not all(math.isfinite(v) and v >= 0 for v in parameters) or ppm >= 1e6:
                raise ValueError("预算参数无效。")
            base = (row["original_envelope_ms"] + allowance / 1000 +
                    skew / 1e6) / (1 - ppm * 1e-6)
            scenario = row["conditional_scenarios_ms"]
            if abs(base - scenario["0"]) > 1e-10:
                raise ValueError("批次条件性包络计算不一致。")
            return dict(
                status="matched", summary_relative=profile["summary"],
                summary_sha256=profile["sha256"], record=dict(key=raw["key"], trial=raw["trial"]),
                additional_empirical_allowance_us=allowance,
                scope_assumed_base_ppm=ppm, scope_official_typical_base_ppm=
                budget["scope_official_typical_base_ppm"],
                scope_aging_ppm_per_year=aging, channel_skew_max_ns=skew,
                phase_increment_us=row["phase_increment_us"],
                batch_max_phase_increment_us=max(
                    r["phase_increment_us"] for r in budget["observations"]),
                batch_record_count=budget["count"],
                batch_key_count=len(budget["keys"]),
                conditional_scenarios_ms=scenario,
                calibration_age_years=None, warmup_temperature_verified=False,
                strict_metrological_upper_bound=False,
                error_budget_verified=False, conditional_below_5ms=None,
                report_relative=str(Path(profile["summary"]).with_name("report.html")),
            )
        return dict(status="unmatched", reason="此记录不属于已登记的复核批次；未套用30 µs等历史余量。")
    except (OSError, ValueError, KeyError, TypeError) as error:
        return dict(status="unmatched", reason=f"批次预算未匹配：{error}")


def section(profile, output, root=None, scope_only=False):
    root = Path(root) if root is not None else ROOT
    if profile["status"] != "matched":
        return ('<h2>滤波与起音分析预算</h2><p>' + html.escape(profile["reason"]) +
                '需以本记录或对应批次的滤波方法、采样率、阈值及降采样相位检查确定经验余量；'
                '不使用固定100 µs占位值，也不重复添加已由最晚起音覆盖的方法差异。</p>')
    link = html.escape(relative_link(
        inside(root, profile["report_relative"]), output), quote=True)
    intro = ('<p>本原始记录已匹配行列联合复核批次，但下列余量仅适用于其联合计时，'
             '不能直接加到本页“推断B”结果上，也不改变本页判定。</p>'
             if scope_only else
             f'<p>原始证据哈希及联合计时均匹配已完成的'
             f'{profile["batch_key_count"]}键、{profile["batch_record_count"]}次相位复核批次。</p>')
    return (
        '<h2>已完成的批次相位复核与条件性预算</h2>' + intro +
        f'<p>统一额外经验分析余量：{profile["additional_empirical_allowance_us"]:g} µs；'
        f'本条新增相位偏移：{profile["phase_increment_us"]:.3f} µs。'
        f'全批次最大新增偏移{profile["batch_max_phase_increment_us"]:.3f} µs，'
        f'向上取整至{profile["additional_empirical_allowance_us"]:g} µs；'
        '不是把原18项极差重复相加。</p>'
        f'<p>本条基础时基假设下的联合条件性包络：'
        f'<strong>{profile["conditional_scenarios_ms"]["0"]:.6f} ms</strong>；'
        f'另加10年漂移情景：{profile["conditional_scenarios_ms"]["10"]:.6f} ms'
        '（非本机已知校准年龄）。</p>'
        f'<p>基础时基使用{profile["scope_assumed_base_ppm"]:g} ppm计算假设；'
        f'官方{profile["scope_official_typical_base_ppm"]:g} ppm带典型值脚注，'
        '不是保证上限。预热、温度和本机校准年龄未核实；经验余量也不是校准误差上限。'
        '因此仅列条件性情景，不自动转成严格验收通过。</p>'
        f'<p><a href="{link}">全键中文预算报告、计算公式与官方资料</a></p>')


def joint_display(result, profile):
    observation = result["conditional_upper_ms"] is None
    if observation and profile["status"] == "matched":
        base = profile["conditional_scenarios_ms"]["0"]
        return dict(
            verdict="批次相位复核完成；列出条件性包络，非严格验收判定",
            timing=f'原未补齐预算包络：{result["unbudgeted_timing_envelope_ms"]:.5f} ms；'
                   f'加入批次经验余量和基础时基假设后：{base:.6f} ms（条件性情景）。',
            allowance=f'{profile["additional_empirical_allowance_us"]:g} µs'
                      '（已匹配本批相位复核，经验值，非校准误差上限）',
            clock=f'{profile["scope_assumed_base_ppm"]:g} ppm计算假设；'
                  '官方15 ppm为典型值；预热、温度及校准年龄未核实',
            caveat='相位复核与经验余量已完成，不再等待24键测量；'
                   '但时基仍是假设，非严格计量上界，不能把条件性情景写成无条件达标。',
        )
    return dict(
        verdict=("仅观察：本记录误差预算尚未匹配，不作达标判定" if observation else
                 "条件性上界小于 5 ms" if result["conditional_below_5ms"] else
                 "未满足上界小于 5 ms"),
        timing=(f'未补齐误差预算的观察值：{result["unbudgeted_timing_envelope_ms"]:.5f} ms，'
                '不能作为达标上界。' if observation else
                f'条件性延迟上界：{result["conditional_upper_ms"]:.5f} ms。'),
        allowance=("未匹配本记录的相位复核；不自动套用历史批次余量" if observation else
                   f'{result["additional_allowance_us"]:g} µs（人工填写，需有分析依据）'),
        clock=("未核实；不能默认零误差" if observation else
               f'{result["scope_clock_error_ppm"]:g} ppm（人工填写，需有规格或校准依据）'),
        caveat=('已计入扫描等待、对齐残差、采样及边界余量；额外分析余量及仪器条件仍需依据。'
                '不表示实测延迟超过5 ms，也不能填零以取得通过。' if observation else
                '本结果依赖人工填写预算及测量假设，不是严格计量上界。'),
    )

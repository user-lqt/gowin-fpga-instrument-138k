"""Measured evidence and explicit human confirmation; never certifies RTL."""

from datetime import datetime
import hashlib
import html
import json
from pathlib import Path

import numpy as np

from lrck_measurement import analyze_edges, decode, write_json
from polyphony_acceptance.report_chinese import metadata_rows
from measurement_files import report_folder, relative_link


def load(folder, name):
    return json.loads((Path(folder) / name).read_text(encoding="utf-8"))


def generate(lrck_folder, polyphony_folder, output, declared_count=None,
             count_user_verified=False):
    if declared_count is not None and (
            type(declared_count) is not int or not 1 <= declared_count <= 4096):
        raise ValueError("独立振荡器数量请输入 1～4096 的整数")
    if type(count_user_verified) is not bool:
        raise ValueError("独立振荡器人工核实状态必须为布尔值")
    if count_user_verified and declared_count is None:
        raise ValueError("人工核实必须对应具体的独立振荡器数量")
    lrck_folder, polyphony_folder = Path(lrck_folder), Path(polyphony_folder)
    lmeta = load(lrck_folder, "capture.json")
    lrck_reports = report_folder(lrck_folder, "lrck")
    poly_reports = report_folder(polyphony_folder, "polyphony")
    lrck = load(lrck_reports, "analysis.json")
    if lmeta.get("kind") != "lrck" or lmeta.get("status") != "complete":
        raise ValueError("LRCK 记录未完成")
    if lrck.get("kind") != "lrck_analysis" or not lmeta.get("wiring_user_confirmed"):
        raise ValueError("缺少有效 LRCK 分析或人工接线确认")
    raw, y, pre = decode((lrck_folder / "raw.bin").read_bytes(), lmeta["waveform"])
    if np.any((raw <= 1) | (raw >= 254)):
        raise ValueError("LRCK 波形接近 ADC 极限")
    computed, _ = analyze_edges(y, pre[4])
    if (lrck["raw_sha256"] != lmeta["waveform"]["sha256"]
            or lrck["source_capture_sha256"] != hashlib.sha256(
                (lrck_folder / "capture.json").read_bytes()).hexdigest()
            or not np.isclose(lrck["measured_lrck_hz"], computed["measured_lrck_hz"], rtol=1e-10)):
        raise ValueError("LRCK 分析与原始记录不一致，请重新离线分析")
    meta, poly = load(polyphony_folder, "capture.json"), load(poly_reports, "analysis.json")
    if meta.get("kind") != "DAC_OUTPUT_SCOPE_CAPTURE" or not meta.get("complete"):
        raise ValueError("不是完整的复音模拟输出记录")
    data = (polyphony_folder / "raw.bin").read_bytes()
    if hashlib.sha256(data).hexdigest() != meta["raw_sha256"]:
        raise ValueError("复音原始数据 SHA256 不匹配")
    if (len(data) != int(meta["preamble"][2])
            or poly.get("capture_sha256") != meta["raw_sha256"]
            or poly.get("source") != meta["kind"]
            or poly.get("samples") != len(data)
            or poly.get("selection") != meta["operator_declared_selection"]
            or poly.get("voices") != meta["operator_declared_voices"]
            or not np.isclose(poly.get("sample_rate_hz", 0), 1 / meta["preamble"][4])):
        raise ValueError("复音分析与采集参数不一致")
    if poly["selection"] != 0:
        raise ValueError("评分汇总需选择 ALL 全声部记录，不能用分组或静音记录")
    lrck_image_hash = lmeta.get("bitstream_sha256_user_file")
    poly_image_hash = meta.get("bitstream_sha256")
    if lrck_image_hash and poly_image_hash and lrck_image_hash.lower() != poly_image_hash.lower():
        raise ValueError("两份记录的烧录文件哈希不同，不能组合成同一版本的评分证据")
    matched = int(poly["matched_enabled_peaks"])
    count, expected = int(poly["voices"]), int(poly["expected_peaks"])
    if not 1 <= count <= 4096 or expected != count or not 0 <= matched <= expected:
        raise ValueError("复音配置数量、ALL 预期峰数或匹配峰数不一致，请重新分析")
    hashes_match = bool(lrck_image_hash and poly_image_hash
                        and lrck_image_hash.lower() == poly_image_hash.lower())
    if poly.get("bitstream_sha256") != poly_image_hash:
        raise ValueError("复音分析的固件哈希与采集记录不一致，请重新分析")
    complete_output = matched == expected and poly.get("spectral_check") == "PASS"
    conditional = (declared_count * computed["measured_lrck_hz"]
                   if declared_count is not None else None)
    count_basis = ("已人工核实，依据见技术文档（用户确认；非软件自动审查）"
                   if count_user_verified else
                   "由技术文档佐证；本报告未记录人工核实确认")
    count_note = ("未选择独立振荡器数量，吞吐量暂不计算。"
                  if declared_count is None else
                  f"独立振荡器：{declared_count} 个；{count_basis}。")
    throughput_note = ("不会用配置数量或谱峰数量直接替代独立振荡器数量。"
                       if conditional is None else
                       f"吞吐量计算：{declared_count} × {computed['measured_lrck_hz']:.3f}"
                       f" = {conditional:,.3f} 振荡器·采样/秒；"
                       + ("数量已人工核实，采样率来自 LRCK 实测；" if count_user_verified else
                          "以所选数量为计算前提；")
                       + "该计算不是正式比赛评分。")
    warnings = [
        "配置声部数来自采集配置，不是 RTL 独立相位/频率/包络审查结果。",
        "频谱峰只提供可听输出证据，不自动等于独立振荡器。",
        "两次采集是否为同一烧录版本需要人工核对；软件不会读取 FPGA 固件。",
        f"独立振荡器数量依据：{count_basis}；不等同于比赛验收通过。",
        "分组/静音对照、实时合成、无预录播放与工程构建对应应分别提供证据；"
        "本汇总不自动核查这些项目，也不将其一并判定为完成或失败。",
        "复音工具的杂散、幅度等质量阈值是工具自检标准，不是赛题直接规定。",
    ]
    if not lrck_image_hash or not poly_image_hash:
        warnings.append("至少一份记录缺少烧录文件哈希，版本对应关系尚未核实。")
    if poly.get("spectral_check") != "PASS":
        warnings.append("当前复音工具自检未通过，需查看原报告；不能作为已通过的全声部证据。")
    if count > matched:
        warnings.append(f"配置声部数 {count} 超过当前匹配谱峰 {matched}，缺少对应输出证据。")
    if declared_count is not None and declared_count > matched:
        warnings.append(f"所选独立振荡器数量 {declared_count} 超过匹配谱峰 {matched}，当前频谱不足以支持该数量。")
    result = {
        "kind": "conditional_scoring_evidence",
        "generated_at": datetime.now().astimezone().isoformat(),
        "lrck_folder": str(lrck_folder.resolve()),
        "polyphony_folder": str(polyphony_folder.resolve()),
        "lrck_raw_sha256": lmeta["waveform"]["sha256"],
        "polyphony_raw_sha256": meta["raw_sha256"],
        "lrck_analysis_sha256": hashlib.sha256((lrck_reports / "analysis.json").read_bytes()).hexdigest(),
        "polyphony_analysis_sha256": hashlib.sha256((poly_reports / "analysis.json").read_bytes()).hexdigest(),
        "configured_voices": count,
        "declared_independent_oscillators": declared_count,
        "independent_oscillator_count_basis": count_basis,
        "independent_oscillator_count_user_verified": count_user_verified,
        "conditional_oscillator_samples_per_second": conditional,
        "verified_independent_oscillators": None,
        "rtl_independence_verified": False, "same_loaded_firmware_verified": False,
        "recorded_firmware_hashes_match": hashes_match,
        "all_output_spectral_evidence_complete": complete_output,
        "lrck_firmware_user_reported": lmeta["firmware_user_reported"],
        "lrck_bitstream_sha256_user_file": lrck_image_hash,
        "polyphony_bitstream_user_reported": meta.get("operator_declared_bitstream"),
        "polyphony_bitstream_sha256": meta.get("bitstream_sha256"),
        "measured_output_sample_rate_hz": computed["measured_lrck_hz"],
        "scope_capture_sample_rate_hz": poly["sample_rate_hz"],
        "matched_spectral_peaks": matched, "expected_spectral_peaks": expected,
        "spectral_tool_check": poly.get("spectral_check"),
        "confirmed_oscillator_samples_per_second": None,
        "contest_acceptance": "NOT_DETERMINED",
        "warnings": warnings,
    }
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    write_json(output / "summary.json", result)
    rows = metadata_rows(result, exclude=("warnings",))
    cautions = "".join(f"<li>{html.escape(v)}</li>" for v in warnings)
    checks = (
        ("LRCK 原始记录与分析", "已核对"),
        ("配置声部数", f"{count}（来自复音采集配置，不是独立数量）"),
        ("ALL 目标谱峰", f"{matched} / {expected}；" + ("工具自检通过" if complete_output else "输出证据不完整")),
        ("记录中固件文件哈希", "一致，非板上读回确认" if hashes_match else "缺少哈希，不能确认一致"),
        ("RTL 独立相位、频率、包络",
         "结构依据见技术文档；本工具不自动审查 RTL，数量的人工核实记录见下项"),
        ("分组 / 静音对照", "由对应对照测量报告佐证；本汇总未自动核查"),
        ("实时合成、无预录播放", "由 RTL 与技术文档佐证；本汇总未自动核查"),
        ("固件与工程构建对应", "由构建记录佐证；文件哈希一致不等于板上读回确认"),
        ("独立振荡器数量", count_note),
        ("吞吐量计算（非正式评分）", throughput_note),
    )
    check_rows = "".join(f"<tr><th>{html.escape(k)}</th><td>{html.escape(v)}</td></tr>" for k,v in checks)
    source_links = "".join(
        f'<li><a href="{html.escape(relative_link(path, output), quote=True)}">{label}</a></li>'
        for path, label in ((lrck_reports / "report.html", "LRCK 采样率报告"),
                            (poly_reports / "report.html", "复音 ALL 频谱报告")))
    (output / "report.html").write_text(
        '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>评分证据汇总</title>'
        '<style>body{font:16px sans-serif;max-width:1100px;margin:32px auto;padding:16px}'
        'td,th{border:1px solid #ccc;padding:8px;text-align:left;overflow-wrap:anywhere}'
        'table{width:100%;border-collapse:collapse}</style><h1>评分证据汇总：实测与核查记录</h1>'
        f'<p>实测输出采样率：{computed["measured_lrck_hz"]:.3f} Hz；'
        f'复音配置 {count} 个声部，匹配 {matched} 个目标谱峰。</p>'
        f'<p><strong>{html.escape(count_note)}</strong></p>'
        f'<p>{html.escape(throughput_note)}</p>'
        f'<table>{check_rows}</table><ul>{source_links}</ul>'
        f'<ul>{cautions}</ul><table>{rows}</table>', encoding="utf-8")
    return output / "report.html"

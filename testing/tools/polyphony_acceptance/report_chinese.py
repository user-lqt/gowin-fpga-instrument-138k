"""Chinese presentation helpers; machine-readable field names stay stable."""

from functools import lru_cache
import html

import matplotlib
from matplotlib import font_manager


@lru_cache(maxsize=1)
def chinese_font():
    for name in ("Microsoft YaHei", "SimHei", "Noto Sans CJK SC", "WenQuanYi Micro Hei"):
        try:
            font_manager.findfont(name, fallback_to_default=False)
            return name
        except ValueError:
            continue
    raise RuntimeError("未找到中文绘图字体，请安装微软雅黑、黑体或 Noto Sans CJK SC。")


def configure_plot():
    matplotlib.rcParams.update({
        "font.family": "sans-serif", "font.sans-serif": [chinese_font(), "DejaVu Sans"],
        "axes.unicode_minus": False, "svg.fonttype": "none",
    })


def source_name(value):
    return {
        "DAC_OUTPUT_SCOPE_CAPTURE": "DAC 模拟输出实测",
        "DAC_OUTPUT_SCOPE_COMPARISON": "DAC 模拟输出对照实测",
        "NON_DAC_COMPARISON": "非 DAC 数据对照（不能作为 DAC 输出证据）",
    }.get(value, "其他数据来源（原标识：" + str(value) + "）")


def verdict(value):
    return {"PASS": "通过", "FAIL": "未通过", "NOT_DETERMINED": "未判定"}.get(value, "未判定")


def selection_name(value):
    value = int(value)
    return "全声部开启" if value == 0 else f"第 {value} 组" if value <= 4 else f"声部 {value - 4:02d} 静音"


LABELS = {
    "kind": "记录类型", "generated_at": "生成时间",
    "measured_lrck_hz": "LRCK 实测频率（Hz）", "mean_period_us": "平均周期（µs）",
    "min_period_us": "最短周期（µs）", "max_period_us": "最长周期（µs）",
    "period_std_ns_observed": "观测周期标准差（ns，含仪器误差）",
    "complete_periods": "完整周期数", "samples_per_period": "每周期采样点数",
    "level_low_v": "低电平估计（V）", "level_high_v": "高电平估计（V）",
    "threshold_v": "边沿判定阈值（V）", "sample_interval_ns": "采样间隔（ns）",
    "relative_to_nominal_48000_ppm": "相对标称 48 kHz 的偏差（ppm）",
    "method": "计算方法", "raw_sha256": "原始数据 SHA256",
    "scope_identity": "示波器身份", "scope_sample_rate_hz": "示波器采集采样率（Hz）",
    "firmware_user_reported": "人工记录的固件版本",
    "bitstream_sha256_user_file": "人工指定烧录文件 SHA256",
    "wiring_user_confirmed": "接线已经人工确认",
    "source_capture_sha256": "采集元数据 SHA256",
    "lrck_folder": "LRCK 记录目录", "polyphony_folder": "复音记录目录",
    "lrck_raw_sha256": "LRCK 原始数据 SHA256", "polyphony_raw_sha256": "复音原始数据 SHA256",
    "lrck_analysis_sha256": "LRCK 分析文件 SHA256",
    "polyphony_analysis_sha256": "复音分析文件 SHA256",
    "declared_independent_oscillators": "独立振荡器数量（技术文档佐证）",
    "independent_oscillator_count_basis": "独立振荡器数量依据",
    "independent_oscillator_count_user_verified": "数量及独立性已人工核实（用户确认）",
    "configured_voices": "复音配置声部数（不是独立振荡器数量）",
    "verified_independent_oscillators": "软件自动审查 RTL 得到的独立振荡器数量",
    "recorded_firmware_hashes_match": "记录中固件文件哈希一致（非板上读回）",
    "all_output_spectral_evidence_complete": "ALL 目标谱峰齐全且工具自检通过",
    "confirmed_oscillator_samples_per_second": "正式评分吞吐量（振荡器·采样/秒）",
    "rtl_independence_verified": "RTL 独立性软件自动核查",
    "same_loaded_firmware_verified": "板上同版本核查",
    "lrck_firmware_user_reported": "LRCK 测量固件（人工记录）",
    "lrck_bitstream_sha256_user_file": "LRCK 烧录文件 SHA256（人工指定）",
    "polyphony_bitstream_user_reported": "复音烧录文件（人工指定）",
    "polyphony_bitstream_sha256": "复音烧录文件 SHA256",
    "measured_output_sample_rate_hz": "实测音频输出采样率（Hz）",
    "scope_capture_sample_rate_hz": "复音示波器采集采样率（Hz）",
    "matched_spectral_peaks": "匹配谱峰数", "expected_spectral_peaks": "预期谱峰数",
    "spectral_tool_check": "复音工具自检",
    "conditional_oscillator_samples_per_second": "计算吞吐量（振荡器·采样/秒，非正式评分）",
    "contest_acceptance": "比赛验收结论",
    "voice": "声部", "enabled": "开启状态", "nominal_hz": "设计频率（Hz）",
    "predicted_hz": "时钟拟合后的预期频率（Hz）", "measured_hz": "实测频率（Hz）",
    "amplitude_peak": "谱峰幅度（V）", "relative_db": "相对幅度（dB）",
    "snr_db": "谱峰信噪比估计（dB）", "present": "检出谱峰",
    "match": "目标检查", "frequency_error_hz": "频率偏差（Hz）",
}


def display_value(key, value):
    if key == "verified_independent_oscillators" and value is None:
        return "未执行自动审查；人工核实状态单独记录"
    if key == "confirmed_oscillator_samples_per_second" and value is None:
        return "未判定（本工具不出具正式比赛评分）"
    if key == "rtl_independence_verified":
        return "已执行并核实" if value else "未执行；不代表未人工核实"
    if key == "same_loaded_firmware_verified":
        return "已核实" if value else "未核实"
    if key == "independent_oscillator_count_user_verified":
        return "已人工核实，依据见技术文档" if value else "本报告未记录人工核实确认"
    if key in ("spectral_tool_check", "contest_acceptance"):
        return verdict(value)
    if value is None:
        return "未记录"
    if isinstance(value, bool):
        if key == "enabled":
            return "开启" if value else "关闭"
        if key == "match":
            return "符合" if value else "不符合"
        return "是" if value else "否"
    if isinstance(value, str):
        return {
            "lrck_analysis": "LRCK 采样率分析",
            "conditional_scoring_evidence": "条件性评分证据汇总",
            "Qualified rising edges, linear threshold interpolation, all complete periods":
                "筛选有效上升沿，线性插值定位阈值，使用全部完整周期",
            "polyphase": "多相 FIR 滤波", "block_mean": "分块均值",
        }.get(value, value)
    return str(value)


def metadata_rows(result, exclude=()):
    return "".join(
        f"<tr><th>{html.escape(LABELS.get(key, key))}</th>"
        f"<td>{html.escape(display_value(key, value))}</td></tr>"
        for key, value in result.items() if key not in exclude)

"""Offline CH2 spectrum from a complete latency capture; not a latency verdict."""

import argparse
import csv
import hashlib
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy.fft import rfft, rfftfreq
from scipy.signal.windows import hann
from polyphony_acceptance.report_chinese import configure_plot
from measurement_files import report_folder


def compute_spectrum(samples, sample_rate):
    samples = np.asarray(samples, dtype=np.float64)
    if samples.ndim != 1 or samples.size < 16 or not np.all(np.isfinite(samples)):
        raise ValueError("Invalid waveform")
    if not np.isfinite(sample_rate) or sample_rate <= 0:
        raise ValueError("Invalid sample rate")
    window = hann(samples.size, sym=False)
    centered = samples - samples.mean()
    magnitude = np.abs(rfft(centered * window)) * (2 / window.sum())
    magnitude[0] *= .5
    if samples.size % 2 == 0:
        magnitude[-1] *= .5
    return rfftfreq(samples.size, 1 / sample_rate), magnitude


def generate(folder):
    configure_plot()
    folder = Path(folder)
    output = report_folder(folder, "latency")
    output.mkdir(parents=True, exist_ok=True)
    trial = json.loads((folder / "trial.json").read_text(encoding="utf-8"))
    if trial.get("status") != "complete":
        raise ValueError("Capture is not complete")
    metadata = json.loads((folder / "metadata.json").read_text(encoding="utf-8"))
    entry = metadata["CH2"]
    data = (folder / "ch2.bin").read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest.lower() != entry["sha256"].lower():
        raise ValueError("CH2 SHA256 mismatch")
    pre = np.array([float(value) for value in entry["preamble"].split(",")])
    if len(pre) != 10 or not np.all(np.isfinite(pre)) or pre[4] <= 0 or pre[7] <= 0:
        raise ValueError("Invalid waveform preamble")
    if pre[0] != 0 or pre[1] != 2 or len(data) != int(pre[2]):
        raise ValueError("Invalid RAW BYTE length/type")
    codes = np.frombuffer(data, dtype=np.uint8)
    voltage = (codes.astype(float) - pre[8] - pre[9]) * pre[7]
    rate = 1 / pre[4]
    hz, amplitude = compute_spectrum(voltage, rate)
    band = (hz > 0) & (hz <= min(20000, rate / 2))
    x, y = hz[band], amplitude[band]
    if not len(x):
        raise ValueError("Record too short to contain an audio-frequency FFT bin")
    result = {
        "source": "保存的 CH2 DAC 模拟输出 RAW BYTE 数据，不是示波器屏幕截图",
        "raw_sha256": digest, "samples": len(codes), "sample_rate_hz": rate,
        "record_seconds": len(codes) / rate,
        "start_seconds_relative_trigger": float(pre[5] - pre[6] * pre[4]),
        "end_seconds_relative_trigger": float(pre[5] + (len(codes)-1-pre[6]) * pre[4]),
        "fft_bin_spacing_hz": rate / len(codes),
        "window": "周期 Hann 窗，使用完整记录，去均值，不重采样、不补零",
        "amplitude": "相干增益校正的单边幅度；dBV 以 1 V 为参考，不是 dBFS",
        "near_rail_samples": int(((codes <= 1) | (codes >= 254)).sum()),
        "raw_voltage_step_v": float(pre[7]),
        "largest_audio_bin_hz": float(x[np.argmax(y)]),
        "caution": "包含静音与起音，不能作为稳态音调幅度或延迟证明。"
                   "Hann 窗的实际频率分辨能力弱于频点间隔，短记录不能可靠分辨 50 Hz。",
    }
    fig, ax = plt.subplots(figsize=(11, 4.8), layout="constrained")
    ax.plot(x, 20 * np.log10(np.maximum(y, 1e-15)), color="#17675c", linewidth=1)
    ax.set(xlabel="频率（Hz）", ylabel="幅度（dBV，以 1 V 为参考）",
           xlim=(0, min(20000, rate/2)),
           title=f"K{trial['key']} / 第 {trial['trial']} 次 | CH2 完整记录实测频谱")
    ax.grid(alpha=.18)
    notes = (f"记录 {len(codes)/rate*1000:.2f} ms | 频点间隔 {rate/len(codes):.2f} Hz"
             f" | Hann 窗 | 接近量程极限的样本 {result['near_rail_samples']} 个\n"
             "包含静音与起音；不是稳态幅度、示波器原屏或延迟判定。")
    fig.supxlabel(notes, fontsize=9)
    fig.savefig(output / "audio_spectrum.png", dpi=150)
    plt.close(fig)
    with (output / "audio_spectrum.csv").open("w", newline="", encoding="utf-8-sig") as target:
        writer = csv.writer(target)
        writer.writerow(("频率（Hz）", "幅度（V）", "幅度（dBV）"))
        writer.writerows(zip(x, y, 20*np.log10(np.maximum(y, 1e-15))))
    (output / "audio_spectrum.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    return output / "audio_spectrum.png"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    print(generate(parser.parse_args().folder))

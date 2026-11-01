"""Read-only checks for this project's DS2202A measurement profiles."""

from dataclasses import dataclass, field
import math
import socket

PROFILE_NAMES = {
    "polyphony": "复音稳态频谱",
    "latency": "按键延迟：手动波形下载",
    "latency_joint": "按键延迟：自动联合采集",
    "lrck": "LRCK 输出采样率",
}
JOINT_TRIGGER_COMMANDS = (
    ":TRIG:MODE?", ":TRIG:EDGE:SOUR?", ":TRIG:EDGE:SLOP?", ":TRIG:EDGE:LEV?",
)


def joint_trigger_errors(values):
    errors = []
    if values[":TRIG:MODE?"].upper() != "EDGE":
        errors.append("自动联合测量需设为边沿触发。")
    if values[":TRIG:EDGE:SOUR?"].upper() not in ("CHAN1", "CH1"):
        errors.append("自动联合测量触发源必须为 CH1 列母线。")
    if values[":TRIG:EDGE:SLOP?"].upper() not in ("NEG", "NEGATIVE"):
        errors.append("自动联合测量须设为 CH1 下降沿触发。")
    level = float(values[":TRIG:EDGE:LEV?"])
    if not math.isfinite(level) or not .5 <= level <= 2.5:
        errors.append("自动联合测量 CH1 触发电平须在 0.5～2.5 V。")
    return errors


@dataclass
class CheckResult:
    values: dict = field(default_factory=dict)
    errors: list = field(default_factory=list)
    notes: list = field(default_factory=list)
    warnings: list = field(default_factory=list)
    profile: str = ""
    purpose: str = ""

    def text(self):
        lines = ["示波器检查：" + ("通过" if not self.errors else "未通过")]
        if self.profile:
            lines.extend(("检查用途：" + self.profile, "检查阶段：" + self.purpose))
        lines.extend(f"{key}：{value}" for key, value in self.values.items())
        lines.extend("不达标：" + value for value in self.errors)
        lines.extend("建议（可继续）：" + value for value in self.warnings)
        lines.extend("提示：" + value for value in self.notes)
        return "\n".join(lines)


def evaluate(values, mode, channel=1, require_stop=True):
    """Limits are project acquisition policy, not instrument specifications."""
    if mode not in PROFILE_NAMES or channel not in (1, 2):
        raise ValueError("Invalid measurement profile")
    result = CheckResult(dict(values), profile=PROFILE_NAMES[mode],
                         purpose=("执行前检查（须 STOP）" if require_stop else
                                  "只读设置检查（无需 STOP，不启动或停止采集）"))
    latency = mode in ("latency", "latency_joint")
    errors = result.errors
    warnings = result.warnings

    def number(key):
        value = float(values[key])
        if not math.isfinite(value):
            raise ValueError(f"{key} 返回非有限数")
        return value

    identity = values["*IDN?"].upper()
    if "RIGOL" not in identity or "DS2202A" not in identity:
        errors.append("仪器必须为 RIGOL DS2202A。")
    if latency and "DS2D192700914" not in identity:
        errors.append("延迟采集器绑定 DS2D192700914，请核对仪器。")
    if values[":TRIG:STAT?"].upper() != "STOP":
        if require_stop:
            errors.append("执行下载或启动联合采集前，请先手动停止采集（STOP）。")
        else:
            result.notes.append("当前未停止：连接与设置仍可检查；下载已有波形或启动联合采集前需先 STOP。"
                                "本次检查不会停止或启动采集。")
    if values[":ACQ:TYPE?"].upper() not in ("NORM", "NORMAL"):
        errors.append("采集方式需为 Normal，不能使用平均、峰值检测或高分辨率模式。")
    rate = number(":ACQ:SRAT?")
    depth = number(":ACQ:MDEP?")
    scale = number(":TIM:SCAL?")
    offset = number(":TIM:OFFS?")
    if min(rate, depth, scale) <= 0:
        raise ValueError("采样率、存储深度或时基无效，请停止后重试。")
    duration = (depth - 1) / rate
    # The saved project captures use 14 horizontal divisions.
    left, right = offset - 7 * scale, offset + 7 * scale
    result.notes.append(f"记录约 {duration * 1000:.2f} ms；屏幕水平窗口约 "
                        f"{left * 1000:.2f}～{right * 1000:.2f} ms（相对触发）。")
    channels = (1, 2) if latency else (channel,)
    for index in channels:
        prefix = f":CHAN{index}:"
        if values[prefix + "DISP?"].upper() not in ("1", "ON"):
            errors.append(f"CH{index} 必须开启。")
        if values[prefix + "COUP?"].upper() != "DC":
            warnings.append(f"CH{index} 建议为 DC 耦合，当前可能改变"
                            + ("数字边沿。" if mode == "lrck" or latency and index == 1 else "音频波形。"))
        if mode != "lrck" and not math.isclose(number(prefix + "PROB?"), 1):
            warnings.append(f"CH{index} 倍率不是 1x，请与实际探头核对，否则电压换算不正确。")
        vertical = number(prefix + "SCAL?")
        vertical_offset = number(prefix + "OFFS?")
        if vertical <= 0:
            errors.append(f"CH{index} 量程无效。")
            continue
        low, high = -vertical_offset - 4 * vertical, -vertical_offset + 4 * vertical
        if mode == "lrck":
            if not low <= 0 or not high >= 3.3:
                warnings.append(f"CH{index} 建议完整显示 0～3.3 V 数字信号，请检查量程和偏移。")
            result.notes.append("LRCK 探头倍率须与示波器设置一致；10x 探头和普通 1x 夹线不能混用倍率。")
        elif latency and index == 1:
            if not .2 <= vertical <= 1:
                warnings.append("CH1 建议 0.2～1 V/div，当前量程仍可下载。")
            if not low <= -.1 or not high >= 3.4:
                warnings.append("CH1 建议显示约 -0.1～3.4 V，请核对是否削顶。")
        else:
            if not .02 <= vertical <= .5:
                warnings.append(f"CH{index} 音频建议 20～500 mV/div；1 V/div 等其他量程也可下载，"
                                "但需检查分辨率和削顶。")
            if latency and (not low <= -.1 or not high >= .1):
                warnings.append(f"CH{index} 建议使起音附近 ±0.1 V 在屏幕内。")
    if latency:
        check_latency(result, rate, duration, scale, left, right)
        if mode == "latency_joint":
            errors.extend(joint_trigger_errors(values))
            result.notes.append("联合采集需 Logic 2 与 D0=A 行、D1=B 行、D2=同列；"
                                "本检查只查询示波器，不检测逻辑分析仪或启动 SINGLE。")
        else:
            result.notes.append("手动模式只下载已有 STOP 波形，不要求当前触发器仍为 CH1 下降沿；"
                                "须人工确认已重新采集同一次按键的完整过程。")
        result.notes.append("CH1 接目标列，CH2 接 DAC 模拟 L；仍需核对真实接线、削顶和完整起音。")
    elif mode == "lrck":
        check_lrck(result, rate, duration, scale)
        result.notes.append(f"CH{channel} 接 DAC 数字 LCK，不是模拟 L 或 BCK；"
                            "不要求按键触发前静音或指定触发源，下载后检查有效周期。")
    else:
        check_polyphony(result, rate, duration, scale)
        result.notes.append(f"CH{channel} 接 DAC 模拟输出，测试声部须已稳定；"
                            "不要求指定触发源、边沿或触发前静音。")
    result.notes.append("检查不会读取 FPGA 固件，不能证明物理接线正确、波形有效或比赛验收通过。")
    return result


def check_latency(result, rate, duration, scale, left, right):
    warnings = result.warnings
    if rate < 20_000_000:
        warnings.append("延迟测量建议至少 20 MSa/s，当前采样率可能降低时序精度。")
    if duration < .025:
        warnings.append("延迟原始记录建议至少 25 ms，当前可能缺少完整过程。")
    if not .002 <= scale <= .010:
        warnings.append("延迟时基建议 2～10 ms/div。")
    if left > -.002 or right < .020:
        warnings.append("水平延迟建议保留触发前至少 2 ms、触发后至少 20 ms；"
                        "例如 5 ms/div、水平偏移 +10 ms。")


def check_lrck(result, rate, duration, scale):
    warnings = result.warnings
    if rate < 10_000_000:
        warnings.append("LRCK 建议至少 10 MSa/s，当前采样率可能不足以定位边沿。")
    if duration < .001:
        warnings.append("LRCK 建议保留至少 1 ms、约 48 个完整周期；下载后将检查实际周期数。")
    if not 10e-6 <= scale <= 100e-6:
        warnings.append("LRCK 建议 10～100 µs/div；频率由原始波形计算，不按屏幕格数推算。")


def check_polyphony(result, rate, duration, scale):
    if rate < 48_000:
        result.errors.append("复音示波器采集率至少 48 kSa/s（不是 DAC 输出采样率）。")
    if duration < 16384 / 48000:
        result.errors.append("复音原始记录至少 0.342 秒。")
    if 14 * scale < 16384 / 48000:
        result.warnings.append("复音屏幕跨度建议至少 0.342 秒，建议 50 ms/div 或更慢。")


def inspect_scope(ip, mode, channel=1, require_stop=True):
    if mode not in PROFILE_NAMES or channel not in (1, 2):
        raise ValueError("Invalid measurement profile")
    commands = ["*IDN?", ":TRIG:STAT?", ":ACQ:TYPE?", ":ACQ:MDEP?",
                ":ACQ:SRAT?", ":TIM:SCAL?", ":TIM:OFFS?"]
    for index in ((1, 2) if mode in ("latency", "latency_joint") else (channel,)):
        commands.extend(f":CHAN{index}:{name}?" for name in
                        ("DISP", "COUP", "PROB", "SCAL", "OFFS"))
    if mode == "latency_joint":
        commands.extend(JOINT_TRIGGER_COMMANDS)
    values = {}
    with socket.create_connection((ip.strip(), 5555), timeout=3) as sock:
        sock.settimeout(3)
        with sock.makefile("rb") as stream:
            for command in commands:
                sock.sendall((command + "\n").encode("ascii"))
                answer = stream.readline(4096)
                if not answer.endswith(b"\n"):
                    raise ValueError(f"{command} 无有效响应")
                values[command] = answer.decode("ascii").strip()
            sock.sendall(b":TRIG:STAT?\n")
            answer = stream.readline(4096)
            if not answer.endswith(b"\n"):
                raise ValueError(":TRIG:STAT? 无有效响应")
            values[":TRIG:STAT?"] = answer.decode("ascii").strip()
    return evaluate(values, mode, channel, require_stop=require_stop)

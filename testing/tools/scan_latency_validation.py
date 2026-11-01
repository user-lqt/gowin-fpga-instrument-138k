"""Offline joint row/column verification. Never accesses an instrument."""

import csv
import hashlib
import html
import json
from pathlib import Path

import numpy as np
from measurement_files import report_folder, relative_link, screen_file


class SignalEvidenceError(ValueError):
    """Preserve exact rejected events rather than reporting total glitch counts."""

    def __init__(self, message, details):
        super().__init__(message)
        self.details = details


def pulses(t, low, trim=False):
    edges = np.diff(np.r_[False, low, False].astype(np.int8))
    start, stop = np.flatnonzero(edges == 1), np.flatnonzero(edges == -1)
    # A pulse touching either recording boundary is not a complete pulse.
    if trim:
        keep = (start > 0) & (stop < len(t))
        start, stop = start[keep], stop[keep]
    elif len(start) and (start[0] == 0 or stop[-1] == len(t)):
        raise ValueError("信号低脉冲触及记录边界；请保留完整的按下前后记录。")
    return t[start], t[stop]


def read_csv(path, names):
    with Path(path).open(encoding="utf-8-sig", newline="") as source:
        reader = csv.DictReader(source)
        if len(set(names)) != 4 or not set(names) <= set(reader.fieldnames or []):
            raise ValueError("时间、A 行、B 行、列必须对应四个不同的 CSV 列名。")
        data = np.array([[float(row[n]) for n in names] for row in reader], dtype=float)
    if data.ndim != 2 or data.shape[0] < 50 or not np.isfinite(data).all():
        raise ValueError("CSV 数据不足或含非有限数值。")
    if np.any(np.diff(data[:, 0]) <= 0):
        raise ValueError("CSV 时间必须严格递增，单位必须是秒。")
    if not np.isin(data[:, 1:], [0, 1]).all():
        raise ValueError("数字通道只接受 0/1，不接受模拟电压或协议解码文本。")
    return data


def row_column_mismatch(data):
    """Diagnose absent row evidence, never infer a missing physical row."""
    t = data[:, 0]
    cs, ce = pulses(t, data[:, 3] == 0, trim=True)
    major = ce-cs > 10e-6
    cs, ce = cs[major], ce[major]
    if len(cs) < 8:
        return None
    rows = []
    for channel in (1, 2):
        start, end = pulses(t, data[:, channel] == 0, trim=True)
        major = end-start > 10e-6
        start, end = start[major], end[major]
        if len(start) < 8:
            return None
        # Startup transients outside the contact interval do not establish
        # its row cadence; all raw column lows still enter the overlap check.
        local = (start >= cs[0]-.0004) & (end <= ce[-1]+.0004)
        local_start, local_end = start[local], end[local]
        if len(local_start) < 8:
            return None
        periods = np.diff(local_start)
        if (not np.all((periods > 190e-6) & (periods < 210e-6))
                or not np.all((local_end-local_start > 20e-6)
                              & (local_end-local_start < 30e-6))):
            return None
        rows.append((start, end))
    # Restrict the diagnostic to times fully covered by both measured rows.
    left = max(s[0] for s, _ in rows)
    right = min(e[-1] for _, e in rows)
    keep = (cs >= left) & (ce <= right)
    cs, ce = cs[keep], ce[keep]
    if len(cs) < 8:
        return None
    low_integral = np.r_[0., np.cumsum(np.diff(t)*(data[:-1, 3] == 0))]
    counts = {}
    for name, (start, end) in zip(("A", "B"), rows):
        core_start, core_end = start+2e-6, end-2e-6
        overlap = (np.interp(core_end, t, low_integral)
                   - np.interp(core_start, t, low_integral))
        counts[name] = int(np.count_nonzero(overlap > 1e-9))
    if any(counts.values()):
        return None
    ast, _ = rows[0]
    index = np.searchsorted(ast, cs, side="right")-1
    phases = (cs-ast[index])*1e6
    p5, median, p95 = np.percentile(phases, [5, 50, 95])
    if p95-p5 > 3:
        return None
    return dict(
        category="row_column_phase_mismatch", column_main_pulses=int(len(cs)),
        row_core_column_low_counts=counts,
        column_after_A_us=dict(p5=float(p5), median=float(median), p95=float(p95)),
        action="先不要重复正式测量。核对当前目标键及 D0=A行、D1=B行、"
               "D2=该键列是否属于同一键；不能仅凭相位判定哪根线错误，"
               "也不能把行信号平移后当作实测 B。",
    )


def main_pulses(t, low, label, boundary_edges=None, trim=False, initial_a_events=(),
                initial_b_events=()):
    """Classify bounded switching artifacts without hiding intermediate pulses."""
    starts, ends = pulses(t, low, trim=trim)
    widths = ends - starts
    major = widths > 10e-6
    permitted_b = np.array([
        any(s == x and e == y for x, y in initial_b_events)
        for s, e in zip(starts, ends)], dtype=bool)
    permitted_a = np.array([
        any(s == x and e == y for x, y in initial_a_events)
        for s, e in zip(starts, ends)], dtype=bool)
    intermediate = (~major) & (widths > 1e-6) & ~permitted_b & ~permitted_a
    if intermediate.any():
        raise SignalEvidenceError(
            f"{label}存在 1～10 µs 的非主脉冲，不能作为边沿短跳变排除。",
            dict(category="intermediate_pulses", channel=label,
                 events=[dict(start_s=float(s), end_s=float(e),
                              width_us=float((e-s)*1e6))
                         for s, e in zip(starts[intermediate], ends[intermediate])]))
    short = ~major
    edges = np.sort(np.r_[starts[major], ends[major]]
                    if boundary_edges is None else boundary_edges)
    if short.any():
        if not len(edges):
            raise ValueError(f"{label}没有可核查的主扫描边界。")
        pos = np.searchsorted(edges, starts[short])
        left = edges[np.clip(pos-1, 0, len(edges)-1)]
        right = edges[np.clip(pos, 0, len(edges)-1)]
        # Both ends must fit within the fixed analysis boundary exclusion band.
        distance = np.minimum(
            np.maximum(abs(starts[short]-left), abs(ends[short]-left)),
            np.maximum(abs(starts[short]-right), abs(ends[short]-right)))
        classified = np.array([
            any(s == x and e == y for x, y in initial_a_events)
            for s, e in zip(starts[short], ends[short])], dtype=bool)
        bad = (distance > 2e-6) & ~classified & ~permitted_b[short]
        if np.any(bad):
            bad_starts, bad_ends = starts[short][bad], ends[short][bad]
            first_main = float(starts[major][0]) if major.any() else None
            details = dict(
                category="unexplained_short_pulses", channel=label,
                rejected_count=int(bad.sum()), total_short_count=int(short.sum()),
                first_main_s=first_main,
                rejected_time_range_s=[float(bad_starts[0]), float(bad_ends[-1])],
                events=[dict(
                    start_s=float(s), end_s=float(e), width_us=float((e-s)*1e6),
                    distance_to_scan_boundary_us=float(d*1e6),
                    relative_to_first_main_us=(
                        float((s-first_main)*1e6) if first_main is not None else None))
                    for s, e, d in zip(bad_starts[:10], bad_ends[:10], distance[bad][:10])],
                action="先离线复核事件位置及模拟列波形；不能把全部短跳变视作违规数，不能随意放宽边界。",
            )
            prefix = ""
            if label == "列信号" and first_main is not None and bad_starts[-1] < first_main:
                prefix = (f"位于首个主列脉冲前 {(first_main-bad_starts[0])*1e6:.3f}～"
                          f"{(first_main-bad_starts[-1])*1e6:.3f} µs；"
                          "可能涉及首次接触瞬态，当前模型无法解释，不能据此认定接线错误。")
            elif label == "列信号" and first_main is not None and bad_starts[0] > first_main:
                prefix = (f"全部异常位于首个主列脉冲后 {(bad_starts[0]-first_main)*1e3:.3f}～"
                          f"{(bad_ends[-1]-first_main)*1e3:.3f} ms（数字记录时间轴）；"
                          "需核对是否处于完整示波器记录范围，不代表起音阶段发生异常。")
            raise SignalEvidenceError(
                f"{label}短跳变远离主扫描边界，不能自动排除。"
                f"实际不符合边界规则 {int(bad.sum())} 个（不是所有 {int(short.sum())} 个短跳变）。"
                + prefix, details)
    return starts[major], ends[major], int(short.sum())


def fit_edges(la_s, la_e, sc_s, sc_e, interval_first_start=False):
    x = np.column_stack((la_s, la_e)).ravel()
    y = np.column_stack((sc_s, sc_e)).ravel()
    if interval_first_start:
        x, y = x[1:], y[1:]
    scale, offset = np.polyfit(x-x[0], y-y[0], 1)
    offset += y[0] - scale*x[0]
    residual = float(np.max(abs(y-(scale*x+offset))))
    return float(scale), float(offset), residual


def previous_a_contact(data, guard=2e-6):
    """Retain a partial A contact in exactly the frame before the first major."""
    t, a, b, c = data.T
    cs, ce = pulses(t, c == 0, trim=True)
    majors = np.flatnonzero(ce-cs > 10e-6)
    if not len(majors) or majors[0] == 0 or c[0] == 0:
        return None
    first = int(majors[0])
    rows = []
    for row in (a, b):
        s, e = pulses(t, row == 0, trim=True)
        keep = e-s > 10e-6
        rows.extend((s[keep], e[keep]))
    ast, ae, bst, be = rows
    ai = int(np.searchsorted(ast, cs[first], side="right")-1)
    if ai < 2:
        return None
    bi = int(np.searchsorted(bst, ast[ai-1]))
    if bi+1 >= len(bst):
        return None
    left, right = ast[ai-1]+guard, min(ae[ai-1], bst[bi])+guard
    if (np.any(cs[:first] < left) or np.any(ce[:first] > right)
            or cs[first] > ast[ai]+guard
            or cs[first] < ast[ai]-guard or abs(ce[first]-ae[ai]) > guard
            or abs(bst[bi]-ast[ai-1]-(ast[ai]-ast[ai-1])/8) > guard):
        return None
    for j in (bi, bi+1):
        start, end = bst[j]+guard, be[j]-guard
        index = max(0, int(np.searchsorted(t, start, side="right"))-1)
        if start >= end or not np.all(np.r_[c[index], c[(t >= start) & (t < end)]] == 1):
            return None
    return dict(
        model="previous_a_contact_interval_v1",
        a_window_logic_s=[float(ast[ai-1]), float(ae[ai-1])],
        allowed_contact_logic_s=[float(left), float(right)],
        following_b_windows_logic_s=[[float(bst[j]), float(be[j])] for j in (bi, bi+1)],
        first_full_a_column_logic_s=[float(cs[first]), float(ce[first])],
        events=[dict(start_s=float(s), end_s=float(e), width_us=float((e-s)*1e6))
                for s, e in zip(cs[:first], ce[:first])],
        policy="仅紧邻首个完整A之前一帧的部分A接触；原始片段完整保留，"
               "不作为同步边沿；两帧B内部数字及模拟列均须为高，"
               "后续所有完整列起止沿仍严格配对；不改变首次B窗口或扫描余量。",
    )


def check_previous_a_scope(contact, scope_t, column, sc_s, scale, offset, fit_limit):
    left, right = np.array(contact["allowed_contact_logic_s"])*scale+offset
    rs, re = pulses(scope_t, column < 1.5, trim=True)
    early = rs < sc_s[0]-2e-6
    if (not early.any() or np.any(rs[early] < left-fit_limit)
            or np.any(re[early] > right+fit_limit)
            or rs[early][0]-scope_t[0] < 2*(sc_s[0]-left)):
        raise ValueError("前帧A接触缺少独立模拟低证据、静止段，或模拟低超出指定A窗口。")
    for event in contact["events"]:
        start = scale*event["start_s"]+offset-fit_limit
        end = scale*event["end_s"]+offset+fit_limit
        if not np.any((re[early] > start) & (rs[early] < end)):
            raise ValueError("前帧A数字接触未获对应原始模拟列低支持。")
    for start, end in contact["following_b_windows_logic_s"]:
        # Expand the boundary exclusion by measured alignment uncertainty,
        # record the complete margin, and retain it in the timing budget.
        start = scale*(start+2e-6)+offset+fit_limit
        end = scale*(end-2e-6)+offset-fit_limit
        values = column[(scope_t >= start) & (scope_t < end)]
        if len(values) < 2 or not np.all(values >= 1.5):
            raise ValueError("前帧A接触进入B内部，不能归类为A独立接触。")
    contact.update(
        raw_analog_events_scope_s=[[float(s), float(e)] for s, e in zip(rs[early], re[early])],
        analog_raw_b_cores_high=True, alignment_witness_tolerance_us=fit_limit*1e6,
        first_a_contact_scope_s=float(rs[early][0]),
    )


def initial_a_transient(t, column, ast, aend, bst, bend, guard, fragments=False):
    """Only the initial A-only contact may supply an interval-valued start."""
    starts, ends = pulses(t, column == 0, trim=True)
    major = np.flatnonzero(ends-starts > 10e-6)
    if not len(major) or major[0] == 0:
        return None
    first = int(major[0])
    widths = ends[:first]-starts[:first]
    if np.any(widths > (10e-6 if fragments else 1e-6)):
        return None
    if fragments and not np.any(widths > 1e-6):
        return None
    if not fragments and not np.any(starts[first]-starts[:first] > guard):
        return None
    ai = int(np.searchsorted(ast, starts[first], side="right")-1)
    bi = int(np.searchsorted(bst, starts[first], side="right"))
    if ai < 0 or bi >= len(bst):
        return None
    left, right = ast[ai]+guard, min(aend[ai], bst[bi])-guard
    if fragments:
        # Unlike A's exit, its entry is not an adjacent A/B boundary.
        # Keep every fragment inside the measured A-low interval, and require
        # the preceding B to have ended before A's entry exclusion band.
        previous_b = bi-1
        if previous_b < 0 or bend[previous_b]+guard >= ast[ai]:
            return None
        left = ast[ai]
    if (not left < starts[first] < right
            or abs(ends[first]-aend[ai]) > guard
            or ends[first] > bst[bi]+guard
            or np.any(starts[:first] < left)
            or np.any(ends[:first] >= right)):
        return None
    # A sparse event CSV needs the state immediately preceding the core too.
    core_start, core_end = bst[bi]+guard, bend[bi]-guard
    index = max(0, int(np.searchsorted(t, core_start, side="right"))-1)
    core_states = np.r_[column[index], column[(t >= core_start) & (t < core_end)]]
    if not np.all(core_states == 1):
        return None
    return dict(
        fragment_interval=fragments,
        a_window_logic_s=[float(ast[ai]), float(aend[ai])],
        a_only_core_logic_s=[float(left), float(right)],
        entry_policy=("measured_A_fall_with_previous_B_separation"
                      if fragments else "guarded_A_core"),
        following_b_window_logic_s=[float(bst[bi]), float(bend[bi])],
        following_b_core_column_high=True,
        events=[dict(start_s=float(s), end_s=float(e), width_us=float((e-s)*1e6))
                for s, e in zip(starts[:first], ends[:first])],
    )


def check_initial_scope_interval(contact, scope_t, scope_column, sc_s, sc_e,
                                 scale, offset, fit_limit):
    """The analog record must independently place all early lows in this A."""
    left, right = np.array(contact["a_only_core_logic_s"])*scale+offset
    if not left <= sc_s[0] <= right:
        raise ValueError("初始 A 接触区间不符：示波器首次下降沿不在同一 A 独占窗口。")
    s, e = pulses(scope_t, scope_column < 1.5, trim=True)
    early = s < sc_e[0]-fit_limit
    a_end = contact["a_window_logic_s"][1]*scale+offset
    if (not early.any() or np.any(s[early] < left)
            or np.any(e[early] > a_end+fit_limit)):
        raise ValueError("初始 A 接触区间不符：模拟列存在窗口外低段或延伸至 B 内部。")
    if contact.get("fragment_interval"):
        for event in contact["events"]:
            start, end = np.array([event["start_s"], event["end_s"]])*scale+offset
            if not np.any((e[early] > start-fit_limit) & (s[early] < end+fit_limit)):
                raise ValueError("首次A数字碎片缺少同一A窗口内的原始模拟列低支持。")
        bs, be = np.array(contact["following_b_window_logic_s"])*scale+offset
        core_start, core_end = bs+2e-6*scale+fit_limit, be-2e-6*scale-fit_limit
        values = scope_column[(scope_t >= core_start) & (scope_t < core_end)]
        if len(values) < 2 or not np.all(values >= 1.5):
            raise ValueError("首次A碎片之后的B内部缺少独立模拟列高证据。")
        contact.update(
            raw_analog_events_scope_s=[[float(x), float(y)]
                                      for x, y in zip(s[early], e[early])],
            analog_following_b_core_high=True,
            analog_witness_tolerance_us=float(fit_limit*1e6),
            first_column_contact_logic_s=contact["events"][0]["start_s"],
        )


def first_a_fragments(data):
    t, a, b, c = data.T
    rows = []
    for row in (a, b):
        start, end = pulses(t, row == 0, trim=True)
        keep = end-start > 10e-6
        rows.extend((start[keep], end[keep]))
    return initial_a_transient(t, c, *rows, 2e-6, fragments=True)


def midwindow_b_contact(t, column, ast, aend, start, end, low_start, low_end,
                        scope_t, scope_column, scale, offset, fit_limit, guard):
    """Witness a single high-to-low transition, not a reopening or A tail."""
    core_start, core_end = start+guard, end-guard
    ai = int(np.searchsorted(ast, start, side="right")-1)
    if (ai < 0 or low_start <= max(core_start, aend[ai]+guard)
            or low_start >= core_end or low_end < core_end
            or abs(low_end-end) > guard):
        return None
    # Examine RAW events: no short pulses or gaps may be silently merged here.
    rs, re = pulses(t, column == 0, trim=True)
    inside = (re > core_start) & (rs < core_end)
    if (np.count_nonzero(inside) != 1 or rs[inside][0] != low_start
            or re[inside][0] != low_end):
        return None
    # Use the unchanged global fit tolerance on both sides of the falling edge.
    # The unambiguous high and low portions must each have actual scope samples.
    high_start = scale*max(core_start, aend[ai]+guard)+offset+fit_limit
    high_end = scale*low_start+offset-fit_limit
    tail_start = scale*low_start+offset+fit_limit
    tail_end = scale*core_end+offset-fit_limit
    dt = float(np.max(np.diff(scope_t)))
    if min(high_end-high_start, tail_end-tail_start) < 2*dt:
        return None
    high = scope_column[(scope_t >= high_start) & (scope_t < high_end)]
    tail = scope_column[(scope_t >= tail_start) & (scope_t < tail_end)]
    if len(high) < 2 or len(tail) < 2 or not np.all(high >= 1.5) or not np.all(tail < 1.5):
        return None
    return dict(
        model="midwindow_b_v1",
        b_window_logic_s=[float(start), float(end)],
        column_low_logic_s=[float(low_start), float(low_end)],
        column_onset_from_b_start_us=float((low_start-start)*1e6),
        column_low_width_us=float((low_end-low_start)*1e6),
        column_low_scope_s=float(scale*low_start+offset),
        scope_high_witness_s=[float(high_start), float(high_end)],
        scope_low_witness_s=[float(tail_start), float(tail_end)],
        raw_digital_core_low_segments=1,
        first_partial_window_preserved=True,
        policy="仅首次 B 证据窗口允许一次内部高到低，并保持至尾部；"
               "A 尾部必须已退出，原始数字内部恰有一段低，模拟列需有独立高段和低段；"
               "随后三个 B 内部窗口完整列低，保留首次部分窗口，不改为下一帧起点。",
    )


def fragmented_initial_b(t, column, ast, aend, bst, bend, guard):
    """Identify one initial B window; retain every raw fragment as evidence."""
    rs, re = pulses(t, column == 0, trim=True)
    for index, (start, end) in enumerate(zip(bst, bend)):
        core_start, core_end = start+guard, end-guard
        touches = (re > core_start) & (rs < core_end)
        if not touches.any():
            continue
        # The earliest B window with any interior low is never skipped.
        if index < 2 or np.count_nonzero(touches) < 2:
            return None
        ai = int(np.searchsorted(ast, start, side="right")-1)
        if ai < 0:
            return None
        segments = np.flatnonzero((re > start-guard) & (rs < end-guard))
        last = int(segments[-1])
        if (re[last]-rs[last] <= 10e-6 or re[last] < core_end
                or abs(re[last]-end) > guard):
            return None
        first = int(segments[0])
        # Only a full same-frame A pulse may serve as the outer leading edge.
        if not (rs[first] <= ast[ai]+guard
                and re[first] >= aend[ai]-guard
                and rs[first] >= ast[ai]-guard):
            return None
        if any(rs[k] < start-guard or re[k] > end+guard for k in segments[1:]):
            return None
        if (rs[last] <= core_start or rs[last] >= core_end
                or index+4 > len(bst)):
            return None
        for bs, be in zip(bst[index+1:index+4], bend[index+1:index+4]):
            j = max(0, int(np.searchsorted(t, bs+guard, side="right"))-1)
            states = np.r_[column[j], column[(t >= bs+guard) & (t < be-guard)]]
            if not np.all(states == 0):
                return None
        events = [dict(start_s=float(rs[k]), end_s=float(re[k]),
                       width_us=float((re[k]-rs[k])*1e6)) for k in segments]
        return dict(
            model="initial_b_fragment_interval_v1",
            b_window_logic_s=[float(start), float(end)],
            composite_column_logic_s=[float(rs[first]), float(re[last])],
            column_low_logic_s=[float(rs[last]), float(re[last])],
            column_onset_from_b_start_us=float((rs[last]-start)*1e6),
            column_low_width_us=float((re[last]-rs[last])*1e6),
            raw_low_segments=events,
            excluded_internal_sync_edges=2*(len(events)-1),
            policy="仅首次B内部碎片化导通单独记录；同期A和B的原始碎片不删除，"
                   "共同列同步只用该帧最外起止沿，其余帧全部起止沿仍配对；"
                   "B核心模拟列高段累计不得超过1微秒，最后低段须有原始模拟低证据，"
                   "随后三个B核心必须完整列低；保留首次窗口，不移到后帧。",
        )
    return None


def short_initial_b(t, column, ast, aend, bst, bend, guard):
    """Identify the earliest B interior low even if its tail is under 10 us."""
    rs, re = pulses(t, column == 0, trim=True)
    for index, (start, end) in enumerate(zip(bst, bend)):
        touches = (re > start+guard) & (rs < end-guard)
        if not touches.any():
            continue
        segments = np.flatnonzero((re > start+guard) & (rs < end-guard))
        last = segments[-1]
        ai = int(np.searchsorted(ast, start, side="right")-1)
        if (index < 2 or ai < 0 or index+4 > len(bst)
                or not 1e-6 < re[last]-rs[last] <= 10e-6
                or rs[last] <= max(start+guard, aend[ai]+guard)
                or rs[last] >= end-guard or abs(re[last]-end) > guard
                or any(re[k]-rs[k] > 1e-6 for k in segments[:-1])
                or np.any(re[segments[:-1]] > rs[last])):
            return None
        for bs, be in zip(bst[index+1:index+4], bend[index+1:index+4]):
            j = max(0, int(np.searchsorted(t, bs+guard, side="right"))-1)
            if not np.all(np.r_[column[j], column[(t >= bs+guard) & (t < be-guard)]] == 0):
                return None
        return dict(
            model="short_initial_b_tail_v1",
            b_window_logic_s=[float(start), float(end)],
            column_low_logic_s=[float(rs[last]), float(re[last])],
            column_onset_from_b_start_us=float((rs[last]-start)*1e6),
            column_low_width_us=float((re[last]-rs[last])*1e6),
            raw_low_segments=[dict(start_s=float(rs[k]), end_s=float(re[k]),
                                   width_us=float((re[k]-rs[k])*1e6)) for k in segments],
            policy="仅首次B末尾短导通；此前B核心无低，随后三帧B核心完整列低；"
                   "该短段不参与共同列同步，原始模拟列须独立证实先高后低且保持至B尾部；"
                   "首次B窗口及前一B起点扫描余量均保留。",
        )
    return None


def check_short_b_scope(contact, scope_t, column, scale, offset, limit, guard):
    start, end = contact["b_window_logic_s"]
    low, tail = contact["column_low_logic_s"]
    high_start = scale*(start+2*guard)+offset+limit
    high_end = scale*low+offset-limit
    low_start = scale*low+offset+limit
    low_end = scale*tail+offset-limit
    high = column[(scope_t >= high_start) & (scope_t < high_end)]
    values = column[(scope_t >= low_start) & (scope_t < low_end)]
    rs, re = pulses(scope_t, column < 1.5, trim=True)
    hits = (rs < low_end) & (re > low_start)
    if (len(high) < 2 or len(values) < 2 or not np.all(high >= 1.5)
            or not np.all(values < 1.5) or np.count_nonzero(hits) != 1
            or abs(re[hits][0]-(scale*tail+offset)) > limit):
        raise ValueError("首次B短尾缺少独立模拟先高后低、稳定低段或尾部对齐证据。")
    contact.update(column_low_scope_s=float(scale*low+offset),
                   scope_high_witness_s=[float(high_start), float(high_end)],
                   scope_low_witness_s=[float(low_start), float(low_end)],
                   first_partial_window_preserved=True,
                   first_short_tail_is_not_sync_edge=True)


def check_fragmented_b_scope(contact, scope_t, column, scale, offset, fit_limit, guard):
    start, end = contact["b_window_logic_s"]
    core_start = scale*(start+guard)+offset
    core_end = scale*(end-guard)+offset
    high_s, high_e = pulses(scope_t, column >= 1.5, trim=True)
    overlaps = np.maximum(0., np.minimum(high_e, core_end)-np.maximum(high_s, core_start))
    # Include boundary-touching high states rather than silently trimming them.
    values = column[(scope_t >= core_start) & (scope_t <= core_end)]
    dt = float(np.max(np.diff(scope_t)))
    if (not len(values) or np.count_nonzero(values >= 1.5)*dt > 1e-6
            or np.sum(overlaps) > 1e-6):
        raise ValueError("首次B碎片窗口的模拟列高段超过1微秒，不满足近连续低证据。")
    stable_start = scale*contact["column_low_logic_s"][0]+offset+fit_limit
    stable_end = core_end-fit_limit
    stable = column[(scope_t >= stable_start) & (scope_t <= stable_end)]
    if len(stable) < 2 or not np.all(stable < 1.5):
        raise ValueError("首次B碎片窗口末尾缺少稳定原始模拟低电平证据。")
    contact.update(
        column_low_scope_s=float(scale*contact["column_low_logic_s"][0]+offset),
        scope_core_high_duration_us=float(np.count_nonzero(values >= 1.5)*dt*1e6),
        scope_stable_low_witness_s=[float(stable_start), float(stable_end)],
        first_partial_window_preserved=True,
    )


def measurement_window(data, allow_initial_prefix=False, allow_previous_a_contact=False,
                       allow_initial_a_fragments=False):
    """Use a fixed 5 ms pre-contact window, never search for a passing segment."""
    t, _, _, column = data.T
    starts, ends = pulses(t, column == 0, trim=True)
    major = np.flatnonzero(ends-starts > 10e-6)
    if not len(major):
        raise SignalEvidenceError(
            "数字记录未发现完整主列导通；"
            f"列低段共 {len(starts)} 个，记录时长 {(t[-1]-t[0]):.3f} s。"
            "本条缺少目标键列导通证据，不能确定B起点，不是延迟超标结论。",
            dict(category="missing_main_column", column_low_segments=len(starts),
                 initial_column_low=bool(column[0] == 0),
                 recording_duration_s=float(t[-1]-t[0]),
                 action="保留原始记录且不计有效次数；核对本次按键动作是否进入逻辑采集窗口、"
                        "所选键与列通道是否对应。不由本条结果直接认定接线错误。"))
    first = starts[major[0]]
    cutoff = first-.005
    policy = dict(policy="首个主列导通前固定 5 ms 至数字记录末尾；不裁剪按下后异常。",
                  original_start_s=float(t[0]), original_end_s=float(t[-1]),
                  first_main_column_s=float(first), excluded_duration_s=0.)
    if cutoff <= t[0]:
        return data, policy
    earlier = (starts < first) & (ends-starts > 1e-6)
    supported_a = ((allow_previous_a_contact and previous_a_contact(data))
                   or (allow_initial_a_fragments and first_a_fragments(data)))
    if earlier.any() and not supported_a:
        events = [dict(start_s=float(s), end_s=float(e), width_us=float((e-s)*1e6),
                       before_first_main_us=float((first-s)*1e6))
                  for s, e in zip(starts[earlier], ends[earlier])]
        raise SignalEvidenceError(
            "主列导通之前已有超过 1 µs 的列低，不能把此前波形直接当作静止段。"
            f"共 {len(events)} 段，位于首个完整主列脉冲前 "
            f"{events[-1]['before_first_main_us']:.3f}～"
            f"{events[0]['before_first_main_us']:.3f} µs，"
            f"最长 {max(p['width_us'] for p in events):.3f} µs。"
            "这是前置列导通证据，不等于记录开头为低，也不是延迟超标结论；"
            "先离线核对前一帧 A/B 行与原始模拟列，不跳过早期接触选择更晚起点。",
            dict(category="prior_column_contact", channel="列信号",
                 first_main_s=float(first), initial_column_low=bool(column[0] == 0),
                 events=events,
                 action="保留数据；先核对前置列低对应的A/B窗口及模拟波形，不直接要求重测或认定接线错误。"))
    if column[0] == 0:
        if not allow_initial_prefix:
            raise ValueError("数字记录起始列低，尚未核对截断前缀；不能据此认定本次按下前静止段不足。")
        periods = []
        for values in data[:, 1:3].T:
            xs, xe = pulses(t, values == 0, trim=True)
            main = xs[xe-xs > 10e-6]
            if len(main) < 20:
                raise ValueError("起始列低前缀缺少独立行扫描周期证据。")
            periods.append(float(np.median(np.diff(main))))
        frame = min(periods)
        high = np.flatnonzero(column == 1)
        prefix_end = max(float(t[high[0]]) if len(high) else float(t[-1]),
                         float(np.max(ends[starts < first], initial=t[0])))
        if (not 0 < frame or abs(periods[0]-periods[1]) > frame*.01
                or prefix_end-t[0] > frame or cutoff-prefix_end < .005):
            raise ValueError("起始列低未限制在首个扫描周期，或与本次按下之间缺少至少10ms静止段。")
        policy["initial_low_prefix"] = dict(
            start_s=float(t[0]), end_s=prefix_end, measured_frame_s=frame,
            quiet_until_first_main_s=float(first-prefix_end),
            policy="仅记录起始截断低及同一首帧内≤1µs短低；随后至少10ms列高；"
                   "完整前缀保留，不证明此前无触点动作，不用此前低段计本次起点。")
    index = max(0, int(np.searchsorted(t, cutoff, side="right"))-1)
    window = data[index:].copy()
    window[0, 0] = cutoff
    policy.update(excluded_duration_s=float(cutoff-t[0]), validated_start_s=float(cutoff),
                  excluded_digital_rows=index,
                  excluded_prefix_is_not_scan_validation=True)
    if allow_initial_a_fragments and supported_a:
        policy["first_a_fragments_preserved"] = supported_a
    return window, policy


def common_scope_tail_window(data, scope_t, scope_intervals, sample_rate_hz, error,
                             allow_fragmented_initial_b=False, first_contact_anchor=False,
                             allow_previous_a_contact=False, allow_short_initial_b=False,
                             allow_initial_a_fragments=False):
    """Bound a late-column-error retry by the entire scope record, never audio."""
    details = getattr(error, "details", {})
    category = details.get("category")
    if (category not in ("intermediate_pulses", "unexplained_short_pulses")
            or details.get("channel") != "列信号"):
        raise error
    t, _, _, column = data.T
    starts, ends = pulses(t, column == 0, trim=True)
    major = ends-starts > 10e-6
    la_s, la_e = starts[major], ends[major]
    fragment = None
    known = set()
    rows = []
    for row in data[:, 1:3].T:
        rs, re = pulses(t, row == 0, trim=True)
        keep = re-rs > 10e-6
        rows.extend((rs[keep], re[keep]))
    initial_a = (initial_a_transient(t, column, *rows, 2e-6,
                                    fragments=allow_initial_a_fragments)
                 if first_contact_anchor else None)
    previous = previous_a_contact(data) if allow_previous_a_contact else None
    short_b = (short_initial_b(t, column, *rows, 2e-6)
               if allow_short_initial_b else None)
    if ((allow_initial_a_fragments and not initial_a)
            or (allow_previous_a_contact and not previous)
            or (allow_short_initial_b and not short_b)):
        raise error
    for events in (initial_a["events"] if initial_a else (),
                   previous["events"] if previous else (),
                   short_b["raw_low_segments"] if short_b else ()):
        known.update((p["start_s"], p["end_s"]) for p in events)
    if allow_fragmented_initial_b:
        fragment = fragmented_initial_b(t, column, *rows, 2e-6)
        if fragment:
            left, right = fragment["composite_column_logic_s"]
            inside = (la_s >= left) & (la_e <= right)
            before, after = la_e <= left, la_s >= right
            if (not inside.any() or not np.all(before | inside | after)
                    or la_s[inside][0] != left or la_e[inside][-1] != right):
                raise error
            la_s, la_e = (np.r_[la_s[before], left, la_s[after]],
                          np.r_[la_e[before], right, la_e[after]])
            known.update((p["start_s"], p["end_s"]) for p in fragment["raw_low_segments"])
    sc_s, sc_e = scope_intervals
    keep = sc_e-sc_s > 10e-6
    sc_s, sc_e = sc_s[keep], sc_e[keep]
    if len(sc_s) < 20 or len(la_s) < len(sc_s):
        raise error
    # Match the same first-B composite used by final verification, when enabled.
    # The final verification still independently checks raw analog B evidence.
    scale, offset, residual = fit_edges(
        la_s[:len(sc_s)], la_e[:len(sc_s)], sc_s, sc_e,
        interval_first_start=initial_a is not None)
    resolution = 1/sample_rate_hz if sample_rate_hz else float(np.max(np.diff(t)))
    fit_limit = 2e-6 + 2*resolution + 2*float(np.max(np.diff(scope_t)))
    if (not np.isfinite([scale, offset, residual]).all()
            or abs(scale-1) > .002 or residual > fit_limit):
        raise error
    scope_end_logic = float((scope_t[-1]-offset)/scale)
    cutoff = scope_end_logic + .001
    if category == "unexplained_short_pulses":
        short_s, short_e = starts[~major], ends[~major]
        edges = np.sort(np.r_[la_s, la_e])
        pos = np.searchsorted(edges, short_s)
        left = edges[np.clip(pos-1, 0, len(edges)-1)]
        right = edges[np.clip(pos, 0, len(edges)-1)]
        distance = np.minimum(np.maximum(abs(short_s-left), abs(short_e-left)),
                              np.maximum(abs(short_s-right), abs(short_e-right)))
        bad = distance > 2e-6
        if known:
            bad &= np.array([(s, e) not in known for s, e in zip(short_s, short_e)])
        if int(bad.sum()) != details.get("rejected_count"):
            raise error
        events = [dict(start_s=float(s), end_s=float(e), width_us=float((e-s)*1e6))
                  for s, e in zip(short_s[bad], short_e[bad])]
    else:
        events = details["events"]
        if known:
            events = [event for event in events
                      if (event["start_s"], event["end_s"]) not in known]
    if (not events or cutoff >= t[-1]
            or any(event["start_s"] <= cutoff+fit_limit/scale for event in events)):
        raise error
    index = int(np.searchsorted(t, cutoff, side="left"))
    window = np.vstack((data[:index], np.r_[cutoff, data[index-1, 1:]]))
    return window, dict(
        policy="仅列异常全部晚于完整示波器终点加固定1ms保留段时，按共同范围重验；"
               "窗口内任何异常仍拒绝，不按声音起点或通过结果挑选终点。",
        original_logic_end_s=float(t[-1]), validated_logic_end_s=float(cutoff),
        scope_end_logic_s=scope_end_logic, retained_tail_guard_us=1000.,
        excluded_tail_duration_s=float(t[-1]-cutoff),
        prefit_scale=scale, prefit_offset_s=offset,
        prefit_max_residual_us=residual*1e6,
        prefit_initial_b_fragment=fragment,
        prefit_initial_a_interval=initial_a,
        prefit_previous_a_contact=previous,
        prefit_short_initial_b=short_b,
        original_full_record_error=str(error), error_category=category,
        excluded_intermediate_events=events if category == "intermediate_pulses" else [],
        excluded_short_events=events if category == "unexplained_short_pulses" else [],
        excluded_tail_is_not_scan_validation=True,
    )


def verify(data, scope_t, scope_column, audio_latest, allowance_us, clock_ppm,
           sample_rate_hz=None, scope_intervals=None, first_contact_anchor=False,
           allow_fragmented_initial_b=False, allow_previous_a_contact=False,
           allow_short_initial_b=False, allow_initial_a_fragments=False):
    """All times use each recorder's native seconds; fit LA -> scope."""
    t, a, b, c = data.T
    resolution = (1 / sample_rate_hz if sample_rate_hz else float(np.max(np.diff(t))))
    if not np.isfinite(resolution) or resolution <= 0:
        raise ValueError("数字采样率必须为有限正数。")
    if resolution > 1e-6:
        raise ValueError("数字采样分辨率超过 1 µs；稀疏 CSV 须提供实际采样率。")
    startup = {"excluded_duration_us": 0., "excluded_short_low_pulses": {}}
    initial_rows = []
    for row in (a, b):
        s, e = pulses(t, row == 0, trim=True)
        major = e-s > 10e-6
        initial_rows.append((s[major], e[major]))
    # Exclude at most the first scan frame, only if its row timing is anomalous
    # and the column contains no substantive contact. Later timing still has
    # to pass every normal check; no search for a convenient stable segment.
    if np.all(data[0, 1:] == 1) and all(len(s) >= 21 for s, _ in initial_rows):
        initial_period = float(np.median(np.diff(initial_rows[1][0])))
        tolerance = 4*resolution + initial_period*.01
        anomalous = any(
            abs(e[0]-s[0]-initial_period/8) > tolerance
            or abs(s[1]-s[0]-initial_period) > tolerance
            for s, e in initial_rows)
        if anomalous:
            cutoff = min(s[1] for s, _ in initial_rows)
            if not 180e-6 < initial_period < 220e-6 or cutoff-t[0] > 440e-6:
                raise ValueError("首帧异常超过有界前导段，不能自动排除。")
            excluded = {}
            for row, name in zip((a, b, c), ("A", "B", "column")):
                s, e = pulses(t, row == 0, trim=True)
                early = s < cutoff
                limit = 1e-6 if name == "column" else 60e-6
                if (np.any(e[early] > cutoff) or np.any(e[early]-s[early] > limit)
                        or (name != "column" and np.count_nonzero((e-s > 10e-6) & early) > 1)):
                    raise ValueError("首帧前导段包含列导通或过长/多个行主脉冲，不能排除。")
                excluded[name] = [
                    {"start_s": float(x), "end_s": float(y), "width_us": float((y-x)*1e6)}
                    for x, y in zip(s[early], e[early])]
            startup = {
                "excluded_duration_us": float((cutoff-t[0])*1e6),
                "excluded_short_low_pulses": {
                    k: sum(p["width_us"] <= 1 for p in v) for k, v in excluded.items()},
                "excluded_pulses": excluded,
                "reason": "仅首个扫描帧宽度/周期异常；≤440 µs 前导段、列无长导通，后续逐帧验证。",
            }
            data = data[t >= cutoff]
            t, a, b, c = data.T
    first_main = []
    for row in (a, b):
        s, e = pulses(t, row == 0, trim=True)
        major = e-s > 10e-6
        if major.any():
            first_main.append(s[major][0])
    # Some saved sessions contain a simultaneous sub-us transition before any
    # full scan starts. Only this bounded prefix may be excluded, never an
    # isolated transition inside the later measurement interval.
    if first_main and np.all(data[0, 1:] == 1):
        cutoff = min(first_main)
        prefix = t < cutoff
        if np.any(data[prefix, 1:] == 0):
            if cutoff-t[0] > 440e-6:
                raise ValueError("首个完整扫描前异常段超过 440 µs，不能自动排除。")
            counts = {}
            for row, name in zip((a, b, c), ("A", "B", "column")):
                s, e = pulses(t, row == 0, trim=True)
                early = s < cutoff
                if np.any((e[early] > cutoff) | (e[early]-s[early] > 1e-6)):
                    raise ValueError("扫描前导段包含长低脉冲或跨界导通，不能作为启动短跳变排除。")
                counts[name] = int(early.sum())
            startup = {"excluded_duration_us": float((cutoff-t[0])*1e6),
                       "excluded_short_low_pulses": counts}
            t, a, b, c = data[~prefix].T
    # A fixed 2 us exclusion band is an analysis policy, not a hardware bound.
    guard = 2e-6
    row_edges = []
    for row in (a, b):
        rs, re = pulses(t, row == 0, trim=True)
        major = re-rs > 10e-6
        row_edges.extend(np.r_[rs[major], re[major]])
    ast, aend, a_short = main_pulses(t, a == 0, "A 行", row_edges, trim=True)
    bst, bend, b_short = main_pulses(t, b == 0, "B 行", row_edges, trim=True)
    if len(bst) < 20 or len(ast) < 20:
        raise ValueError("完整 A/B 扫描周期不足 20 个。")
    periods = np.diff(bst)
    period = float(np.median(periods))
    measured_periods = []
    for label, starts in (("A", ast), ("B", bst)):
        row_periods = np.diff(starts)
        measured_periods.extend(row_periods)
        if (not 180e-6 < period < 220e-6
                or np.any(abs(row_periods-period) > 4*resolution+period*.01)):
            raise ValueError(f"{label} 行主扫描周期异常，存在暂停、缺失或模型不符；不是单纯边沿短跳变。")
    for starts, ends in ((ast, aend), (bst, bend)):
        if np.any(abs((ends - starts) - period / 8) > 4 * resolution + period * .01):
            raise ValueError("行有效宽度不符合八行低有效扫描模型。")
    before = np.searchsorted(ast, bst) - 1
    valid = before >= 0
    boundary_delta = bst[valid] - aend[before[valid]]
    if not valid.any() or np.any(abs(boundary_delta) > guard):
        raise ValueError("A/B 相邻行交界偏差超过 2 µs 排除带，需复核通道映射或真实重叠。")
    # Validate phase as well as pulse width; otherwise swapped/nonadjacent rows can pass.
    if np.any(abs(bst[valid]-ast[before[valid]]-period/8) > 4*resolution+period*.01):
        raise ValueError("A/B 行起点间隔不符合相邻八行扫描模型。")
    if c[0] == 0:
        raise ValueError("逻辑列信号从低电平开始，缺少按下前静止段。")
    # Holding the key may leave the final logic pulse cut by STOP. Only that
    # trailing incomplete pulse is omitted; full scope coverage is checked below.
    previous = (previous_a_contact(np.column_stack((t, a, b, c)), guard)
                if first_contact_anchor and allow_previous_a_contact else None)
    if allow_previous_a_contact and not previous:
        raise ValueError("不满足严格前帧A独立接触模型。")
    contact = (initial_a_transient(t, c, ast, aend, bst, bend, guard,
                                  fragments=allow_initial_a_fragments)
               if first_contact_anchor else None)
    if allow_initial_a_fragments and not contact:
        raise ValueError("不满足同一首次A独占窗口内的碎片区间模型。")
    contact_events = ([(p["start_s"], p["end_s"]) for p in contact["events"]]
                      if contact else ())
    fragmented = (fragmented_initial_b(t, c, ast, aend, bst, bend, guard)
                  if first_contact_anchor and allow_fragmented_initial_b else None)
    fragment_events = ([(p["start_s"], p["end_s"]) for p in fragmented["raw_low_segments"]]
                       if fragmented else ())
    previous_events = ([(p["start_s"], p["end_s"]) for p in previous["events"]]
                       if previous else ())
    short_b = (short_initial_b(t, c, ast, aend, bst, bend, guard)
               if first_contact_anchor and allow_short_initial_b else None)
    if allow_short_initial_b and not short_b:
        raise ValueError("不满足首次B短尾模型。")
    short_events = ([(p["start_s"], p["end_s"]) for p in short_b["raw_low_segments"]]
                    if short_b else ())
    la_s, la_e, column_short = main_pulses(
        t, c == 0, "列信号", trim=True, initial_a_events=contact_events,
        initial_b_events=tuple(fragment_events)+tuple(previous_events)+tuple(short_events))
    if fragmented:
        left, right = fragmented["composite_column_logic_s"]
        inside = (la_s >= left) & (la_e <= right)
        before = la_e <= left
        after = la_s >= right
        if (not inside.any() or not np.all(before | inside | after)
                or la_s[inside][0] != left or la_e[inside][-1] != right):
            raise ValueError("首次B碎片未包含完整主列区间。")
        la_s, la_e = (np.r_[la_s[before], left, la_s[after]],
                      np.r_[la_e[before], right, la_e[after]])
    if scope_intervals is None:
        sc_s, sc_e = pulses(scope_t, scope_column < 1.5)
    else:
        sc_s, sc_e = scope_intervals
    if short_b:
        keep = sc_e-sc_s > 10e-6
        sc_s, sc_e = sc_s[keep], sc_e[keep]
    keep = (sc_e - sc_s) > 10e-6
    sc_s, sc_e = sc_s[keep], sc_e[keep]
    if len(sc_s) < 20 or len(la_s) < len(sc_s):
        raise ValueError("完整列脉冲不足，或逻辑记录未覆盖示波器完整按键过程。")
    # Both recordings must include the first contact. Extra trailing logic
    # pulses are expected when the logic recorder is stopped after the scope.
    all_la_s, all_la_e = la_s, la_e
    la_s, la_e = la_s[:len(sc_s)], la_e[:len(sc_e)]
    if min(la_s[0] - t[0], sc_s[0] - scope_t[0]) < 2 * period:
        raise ValueError("按下前静止段不足两个扫描周期，无法排除周期错位。")
    if np.ptp(la_e - la_s) < period / 16 and not first_contact_anchor:
        raise ValueError("缺少非周期的 A→B 脉宽变化，不能可靠对齐。")
    scale, offset, residual = fit_edges(
        la_s, la_e, sc_s, sc_e, interval_first_start=contact is not None)
    scope_dt = float(np.max(np.diff(scope_t)))
    fit_limit = 2e-6 + 2*resolution + 2*scope_dt
    if abs(scale - 1) > .002 or residual > fit_limit:
        raise ValueError(f"共同列信号全起止沿配对残差 {residual*1e6:.3f} µs，"
                         f"超过允许的 {fit_limit*1e6:.3f} µs，或时钟比例异常；"
                         "不能通过过滤行边沿或放宽扫描模型恢复同步。")
    if contact:
        check_initial_scope_interval(
            contact, scope_t, scope_column, sc_s, sc_e, scale, offset, fit_limit)
        contact.update(
            model=("initial_a_fragment_interval_v1" if allow_initial_a_fragments
                   else "initial_a_interval_v1"),
            first_start_is_interval_not_sync_edge=True,
            first_start_difference_us=float((sc_s[0]-scale*la_s[0]-offset)*1e6),
            retained_sync_edges=int(2*len(sc_s)-1),
            excluded_exact_sync_edges=1,
            policy=("仅首次 A 独占窗口内1～10 µs及更短片段按独立碎片区间模型保留；"
                    "每段须有同一A窗口内原始模拟低支持，紧接B内部须独立模拟列高；"
                    if allow_initial_a_fragments else
                    "仅首次 A 独占窗口内≤1 µs短低段归类为接触瞬态；")
                   +
                   "首个下降沿改作 A 区间约束，首个上升沿及后续全部完整起止沿仍严格配对；"
                   "紧接 B 内部必须列高；不判断电气成因或真实物理闭合。",
        )
    if fragmented:
        check_fragmented_b_scope(
            fragmented, scope_t, scope_column, scale, offset, fit_limit, guard)
    if previous:
        check_previous_a_scope(
            previous, scope_t, scope_column, sc_s, scale, offset, fit_limit)
    if short_b:
        check_short_b_scope(short_b, scope_t, scope_column, scale, offset, fit_limit, guard)
    if scale*all_la_e[-1]+offset < max(sc_e[-1], audio_latest)-fit_limit:
        raise ValueError("逻辑完整脉冲未覆盖示波器记录和模拟起音，不能使用末尾截断脉冲补齐。")
    alternatives = []
    # Reject any one- or two-frame shift still consistent with ALL paired edges,
    # including first contact and the A-to-B width transition.
    for shift in (-2, -1, 1, 2):
        indices = np.arange(max(0, -shift), min(len(sc_s), len(all_la_s)-shift))
        if len(indices) < 20:
            continue
        ls, le = all_la_s[indices+shift], all_la_e[indices+shift]
        alt_scale, alt_offset, alt_residual = fit_edges(
            ls, le, sc_s[indices], sc_e[indices],
            interval_first_start=contact is not None and indices[0] == 0)
        # An alternative cannot hide the first contact inside the other
        # recorder's observed pre-press quiet interval. This is an explicit
        # same-press/first-contact anchor, not uniqueness from a periodic train.
        quiet_conflict = False
        if first_contact_anchor:
            mapped_la_first = alt_scale*all_la_s[0]+alt_offset
            mapped_la_origin = alt_scale*t[0]+alt_offset
            quiet_conflict = bool(
                scope_t[0]+fit_limit < mapped_la_first < sc_s[0]-fit_limit
                or mapped_la_origin+fit_limit < sc_s[0] < mapped_la_first-fit_limit)
        alternatives.append(dict(pulse_index_shift=shift, pairs=len(indices),
                                 max_residual_us=alt_residual*1e6,
                                 conflicts_with_observed_prepress_quiet=quiet_conflict))
        if abs(alt_scale-1) <= .002 and alt_residual <= fit_limit and not quiet_conflict:
            raise ValueError(f"列信号偏移 {shift:+d} 个周期后仍能配对，无法唯一确定同步。")
    # Only the first B evidence window may start low midway; never skip a
    # partial window to select a more convenient later onset.
    observed = []
    full_windows = []
    midwindow = None
    for start, end in zip(bst, bend):
        core_start, core_end = start+guard, end-guard
        if core_end <= core_start:
            raise ValueError("B 行边界排除后没有完整内部窗口。")
        if short_b and start == short_b["b_window_logic_s"][0]:
            if any(observed):
                raise ValueError("短尾之前已存在B导通，不能改选起点。")
            midwindow = short_b
            observed.append(True)
            full_windows.append(False)
            continue
        if fragmented and start == fragmented["b_window_logic_s"][0]:
            if any(observed):
                raise ValueError("碎片化B区间之前已经观察到B导通，不是首次接触。")
            midwindow = fragmented
            observed.append(True)
            full_windows.append(False)
            continue
        index = np.searchsorted(all_la_e, core_start, side="right")
        intersects = index < len(all_la_s) and all_la_s[index] < core_end
        full = bool(intersects and all_la_s[index] <= core_start and all_la_e[index] >= core_end)
        if (intersects and scale*start+offset < audio_latest
                and not full):
            low_start, low_end = all_la_s[index], all_la_e[index]
            candidate = (midwindow_b_contact(
                t, c, ast, aend, start, end, low_start, low_end,
                scope_t, scope_column, scale, offset, fit_limit, guard)
                if first_contact_anchor and not any(observed) else None)
            if candidate:
                midwindow = candidate
                observed.append(True)
                full_windows.append(False)
                continue
            onset_us = float((low_start-start)*1e6)
            reaches_tail = bool(low_end >= core_end)
            details = dict(
                category="partial_b_window", channel="B 行与列",
                b_window_logic_s=[float(start), float(end)],
                b_core_logic_s=[float(core_start), float(core_end)],
                column_low_logic_s=[float(low_start), float(low_end)],
                column_onset_from_b_start_us=onset_us,
                column_low_width_us=float((low_end-low_start)*1e6),
                column_low_reaches_core_end=reaches_tail,
                alignment_scale=scale, alignment_offset_s=offset,
                alignment_max_residual_us=residual*1e6,
                action="先离线查看该 B 窗口的数字行列及模拟列波形；"
                       "中途开始导通与中途断开不能混为一谈，当前完整窗口模型不适用；"
                       "无需仅因该提示重复采集，也不据此认定延迟超标或接线错误。",
            )
            state = ("窗口中途开始的低段保持至内部末尾"
                     if onset_us > guard*1e6 and reaches_tail else "内部低段未完整覆盖窗口")
            raise SignalEvidenceError(
                "B 行内部列信号只部分导通或发生跳变，不能自动确定首次持续导通窗口。"
                f"具体 B 窗口 {start:.9f}～{end:.9f} s；"
                f"相关列低段始于窗口起点后 {onset_us:.3f} µs，低宽 {(low_end-low_start)*1e6:.3f} µs；"
                f"{state}。这是当前完整 B 窗口模型不适用，不是延迟超标结论。",
                details)
        observed.append(bool(intersects))
        full_windows.append(full)
    detected = np.flatnonzero(observed)
    if not len(detected) or detected[0] < 2:
        raise ValueError("没有完整的首次 B 导通前扫描证据。")
    j = detected[0]
    if midwindow:
        if j+4 > len(bst) or not all(full_windows[j+1:j+4]):
            raise ValueError("B 中途导通之后未连续保持三个完整 B 窗口；不跳过部分导通寻找更晚起点。")
        midwindow["following_full_b_windows_logic_s"] = [
            [float(s), float(e)] for s, e in zip(bst[j+1:j+4], bend[j+1:j+4])]
    elif j + 3 > len(bst) or not all(observed[j:j+3]):
        raise ValueError("B 导通未连续保持至少三个扫描窗口，需复核触点抖动。")
    b_begin, b_end = scale * bst[j] + offset, scale * bend[j] + offset
    if not b_end < audio_latest < scope_t[-1]:
        raise ValueError("模拟起音不在首次 B 窗口之后的记录范围内，需复核同步与起音。")
    earliest = scale * bst[j-1] + offset
    boundary_margin = 2*scale*guard
    uncertainty = residual + scale * resolution + scope_dt + boundary_margin
    clock_margin = abs(audio_latest - earliest) * clock_ppm * 1e-6
    upper = audio_latest - earliest + uncertainty + allowance_us * 1e-6 + clock_margin
    return {
        "scan_period_min_us": float(min(measured_periods)*1e6),
        "scan_period_max_us": float(max(measured_periods)*1e6),
        "b_window_scope_s": [float(b_begin), float(b_end)],
        "conditional_closure_earliest_scope_s": float(earliest),
        "maximum_scan_allowance_us": float((b_end-earliest)*1e6),
        "alignment_scale": float(scale), "alignment_offset_s": float(offset),
        "alignment_max_residual_us": residual*1e6,
        "digital_resolution_us": resolution*1e6,
        "scope_sample_interval_us": scope_dt*1e6,
        "boundary_policy": "常规仅排除宽度≤1 µs且位于主边界±2 µs内的低跳变；"
                           "首次 A 接触瞬态和首次 B 中途导通独立归类（如有，见明细）；"
                           "首次 B 碎片化接触仅按独立区间模型核对；"
                           "不接受后续 B 窗口内部断开，后续 B 窗口须完整列低。",
        "boundary_exclusion_us": guard*1e6,
        "boundary_additional_margin_us": boundary_margin*1e6,
        "ab_boundary_delta_min_us": float(np.min(boundary_delta)*1e6),
        "ab_boundary_delta_max_us": float(np.max(boundary_delta)*1e6),
        "excluded_short_low_pulses": {
            "A": a_short, "B": b_short, "column": column_short-len(contact_events)
            -len(previous_events)
            -len(short_events)
            -sum(p["width_us"] <= 10 for p in
                 (fragmented["raw_low_segments"] if fragmented else []))},
        "initial_a_contact_transient": contact,
        "previous_a_contact": previous,
        "b_midwindow_contact": midwindow,
        "b_onset_model": (midwindow["model"] if midwindow else "full_b_window_v1"),
        "alignment_rejected_shift_candidates": alternatives,
        "alignment_fit_limit_us": fit_limit*1e6,
        "alignment_first_contact_anchor": bool(first_contact_anchor),
        "alignment_anchor_assumptions": (
            "人工确认同一次、单键按压；两份记录都包含首次列导通前至少两个扫描周期静止段；"
            + ("前帧A部分接触保留并由原始模拟列独立核对；仅后续完整列脉冲作严格同步；"
               if previous else "")
            + ("首次下降沿使用独立 A 区间约束，保留首次上升沿及后续全部起止沿；"
               if contact else "全起止沿逐一配对；")
            + ("仅首次B接触帧使用最外侧起止沿，内部原始片段单列保留、不作为同步边沿；"
               if fragmented else "")
            + "错帧若在对方已观测静止段引入导通则排除。"
            if first_contact_anchor else "要求非周期脉宽变化及全边沿错帧排除。"),
        "logic_trailing_incomplete_pulse_omitted": bool(c[-1] == 0),
        "startup_prefix": startup,
        "audio_latest_scope_s": float(audio_latest),
        "additional_allowance_us": allowance_us, "scope_clock_error_ppm": clock_ppm,
        "conditional_upper_ms": float(upper*1000),
        "conditional_below_5ms": bool(upper < .005),
        "strict_metrological_upper_bound": False,
    }


def timing_ruler(ax, result):
    begin, end = result["b_window_scope_s"]
    earliest = (result["conditional_closure_earliest_scope_s"]-begin)*1000
    delay = (result["audio_latest_scope_s"]-begin)*1000
    window = (end-begin)*1000
    ax.axvspan(earliest, window, color="#87969d", alpha=.15)
    ax.axvline(0, color="#b0283c", ls="--", lw=1)
    ax.axvline(delay, color="#087f8c", ls="--", lw=1)
    transform = ax.get_xaxis_transform()
    ax.annotate("", xy=(0, .8), xytext=(delay, .8),
                xycoords=transform, textcoords=transform,
                arrowprops=dict(arrowstyle="<->", color="#202b30", lw=1.4))
    ax.text(delay/2, .86, f"B 扫描窗口起点 → 最晚模拟起音：{delay:.5f} ms",
            transform=transform, ha="center", va="bottom", fontsize=11, weight="bold",
            bbox=dict(facecolor="white", edgecolor="none", alpha=.95, pad=3))
    ax.text(0, .7, "时间零点：首次 B 扫描窗口起点\n逻辑分析仪对齐；非物理闭合瞬间",
            transform=transform, ha="left", va="top", fontsize=9, color="#b0283c",
            bbox=dict(facecolor="white", edgecolor="none", alpha=.95, pad=2))
    ax.text(delay, .7, f"终点：各方法最晚模拟起音\n示波器 CH2；{delay:.5f} ms",
            transform=transform, ha="right", va="top", fontsize=9, color="#087f8c",
            bbox=dict(facecolor="white", edgecolor="none", alpha=.95, pad=2))
    ax.set_xlim(earliest-.15, delay+.4)
    return delay


def render_midwindow(output, trial, data, result):
    import matplotlib.pyplot as plt
    from latency_waveforms import load
    (column, _), dt, _ = load(trial)
    begin, _ = result["b_window_scope_s"]
    event = result["b_midwindow_contact"]
    mapped = result["alignment_scale"]*data[:, 0]+result["alignment_offset_s"]
    fig, axes = plt.subplots(4, 2, figsize=(14, 8), layout="constrained")
    for j, bounds in enumerate(((-10, 40), (-30, 300))):
        left, right = begin+bounds[0]*1e-6, begin+bounds[1]*1e-6
        s, e = max(0, int(left/dt)), min(len(column), int(right/dt)+1)
        axes[0, j].plot((np.arange(s, e)*dt-begin)*1e6, column[s:e], lw=.8, color="#116b96")
        axes[0, j].axhline(1.5, color="#aa3344", ls=":", lw=1)
        axes[0, j].set(ylabel="CH1 列电压 (V)",
                       title=("首次 B 中途导通：原始模拟与数字证据", "与随后完整 B 窗口对照")[j])
        s = max(0, np.searchsorted(mapped, left)-1)
        e = min(len(mapped), np.searchsorted(mapped, right)+1)
        for i, label in enumerate(("A 行", "B 行", "数字列"), 1):
            axes[i, j].step((mapped[s:e]-begin)*1e6, data[s:e, i], where="post", lw=1)
            axes[i, j].set(ylabel=label, ylim=(-.2, 1.2), yticks=[0, 1])
        for ax in axes[:, j]:
            ax.axvspan(0, (result["b_window_scope_s"][1]-begin)*1e6, color="#087f8c", alpha=.12)
            ax.axvline((event["column_low_scope_s"]-begin)*1e6, color="#aa3344", ls="--", lw=.8)
            ax.set_xlim(*bounds)
            ax.grid(alpha=.2)
        axes[-1, j].set_xlabel("相对首次 B 证据窗口起点 (µs)，不是物理闭合时刻")
    fig.savefig(output/"b_midwindow.png", dpi=160)
    plt.close(fig)


def render_previous_a(output, trial, data, result):
    from latency_waveforms import load
    import matplotlib.pyplot as plt
    (column, _), dt, _ = load(trial)
    contact = result["previous_a_contact"]
    scale, offset = result["alignment_scale"], result["alignment_offset_s"]
    origin = scale*contact["a_window_logic_s"][0]+offset
    mapped = scale*data[:, 0]+offset
    left, right = origin-40e-6, origin+280e-6
    first = max(0, np.searchsorted(mapped, left)-1)
    last = min(len(mapped), np.searchsorted(mapped, right)+1)
    s, e = max(0, int(left/dt)), min(len(column), int(right/dt)+1)
    fig, axes = plt.subplots(4, 1, figsize=(14, 8), layout="constrained", sharex=True)
    axes[0].plot((np.arange(s, e)*dt-origin)*1e6, column[s:e], lw=1)
    axes[0].axhline(1.5, color="#b0283c", ls="--")
    axes[0].set_ylabel("原始 CH1（V）")
    axes[0].set_title("前帧 A 部分接触：保留原始模拟及数字证据，不作为 B 起点")
    for ax, values, name in zip(axes[1:], data[:, 1:].T, ("A 行", "B 行", "列")):
        ax.step((mapped[first:last]-origin)*1e6, values[first:last], where="post")
        ax.set(ylabel=name, ylim=(-.2, 1.2), yticks=[0, 1])
    for ax in axes:
        for start, end in contact["following_b_windows_logic_s"]:
            ax.axvspan((scale*start+offset-origin)*1e6,
                       (scale*end+offset-origin)*1e6, color="#087f8c", alpha=.12)
        ax.set_xlim(-40, 280)
        ax.grid(alpha=.2)
    axes[-1].set_xlabel("相对前帧 A 行起点（µs）；蓝色为 B 扫描范围，其内部已核对列高")
    fig.savefig(output/"previous_a_contact.png", dpi=160)
    fig.savefig(output/"previous_a_contact.svg")
    plt.close(fig)


def render_initial_a_fragments(output, trial, data, result):
    from latency_waveforms import load
    import matplotlib.pyplot as plt
    (column, _), dt, _ = load(trial)
    contact = result["initial_a_contact_transient"]
    scale, offset = result["alignment_scale"], result["alignment_offset_s"]
    origin = scale*contact["a_window_logic_s"][0]+offset
    mapped = scale*data[:, 0]+offset
    left, right = origin-10e-6, origin+70e-6
    first = max(0, np.searchsorted(mapped, left)-1)
    last = min(len(mapped), np.searchsorted(mapped, right)+1)
    s, e = max(0, int(left/dt)), min(len(column), int(right/dt)+1)
    fig, axes = plt.subplots(4, 1, figsize=(14, 8), layout="constrained", sharex=True)
    axes[0].plot((np.arange(s, e)*dt-origin)*1e6, column[s:e], lw=1)
    axes[0].axhline(1.5, color="#b0283c", ls="--")
    axes[0].set(ylabel="原始 CH1（V）", title="首次 A 窗口碎片：保留原始模拟与数字波形，不作为 B 起点")
    for ax, values, name in zip(axes[1:], data[:, 1:].T, ("A 行", "B 行", "数字列")):
        ax.step((mapped[first:last]-origin)*1e6, values[first:last], where="post")
        ax.set(ylabel=name, ylim=(-.2, 1.2), yticks=[0, 1])
    for ax in axes:
        for key, color in (("a_window_logic_s", "#b08000"),
                           ("following_b_window_logic_s", "#087f8c")):
            start, end = contact[key]
            ax.axvspan((scale*start+offset-origin)*1e6,
                       (scale*end+offset-origin)*1e6, color=color, alpha=.12)
        ax.set_xlim(-10, 70)
        ax.grid(alpha=.2)
    axes[-1].set_xlabel("相对首次 A 行起点（µs）；黄色为 A，蓝色为紧接的 B（内部已核对列高）")
    fig.savefig(output/"initial_a_fragments.png", dpi=160)
    fig.savefig(output/"initial_a_fragments.svg")
    plt.close(fig)


def render_report(output, trial, data, result, evidence, ch2, dt, a):
    """Render verified observations without changing analysis or source data."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from scipy.signal import resample_poly
    from polyphony_acceptance.report_chinese import configure_plot
    from polyphony_acceptance.acceptance_reports import page
    from review_latency_evidence import raw_envelope
    configure_plot()
    begin, end = result["b_window_scope_s"]
    mapped = result["alignment_scale"]*data[:, 0]+result["alignment_offset_s"]
    mask = (mapped > begin-.00045) & (mapped < end+.00025)
    fig, axes = plt.subplots(4, 1, figsize=(14, 9), height_ratios=(1.6, 1, 1, 1),
                             layout="constrained")
    fig.suptitle("逻辑分析仪 A/B 行与列信号 | 联合计时标尺", fontsize=13)
    ruler = axes[0]
    timing_ruler(ruler, result)
    ruler.set(ylim=(0, 1), yticks=[], xlabel="相对首次 B 扫描窗口起点（ms）")
    ruler.spines["left"].set_visible(False)
    ruler.text(.5, .08, "灰色：条件性闭合窗口；箭头不含扫描及误差余量，不是条件性上界",
               transform=ruler.transAxes, ha="center", color="#50616b", fontsize=9)
    for ax, values, label, color in zip(
            axes[1:], data[:, 1:].T, ("A 行", "B 行", "列母线"),
            ("#177267", "#b0283c", "#b08000")):
        ax.step((mapped[mask]-begin)*1e6, values[mask], where="post", color=color)
        ax.axvspan(0, (end-begin)*1e6, alpha=.13, color="#087f8c")
        ax.axvline(0, color="#b0283c", ls="--", lw=1)
        ax.set(yticks=[0, 1], ylabel=label, ylim=(-.2, 1.5))
        ax.grid(alpha=.18)
    axes[1].set_title("逻辑分析仪原始数字数据：低电平有效；蓝色区域为首次 B 与列同时有效的扫描窗口")
    if result.get("b_midwindow_contact"):
        axes[1].set_title("首次 B 证据窗口仅后段列低；计时仍从该窗口起点开始，不挪至下一帧")
        for ax in axes[1:]:
            ax.axvline((result["b_midwindow_contact"]["column_low_scope_s"]-begin)*1e6,
                       color="#aa3344", ls=":", lw=1)
    axes[-1].set_xlabel("相对首次 B 扫描窗口起点（µs）")
    fig.savefig(output / "b_window.png", dpi=160)
    fig.savefig(output / "b_window.svg")
    plt.close(fig)

    factor = max(1, round(1/(50000*dt)))
    filtered = resample_poly(ch2, 1, factor)
    t = np.arange(len(filtered))*factor*dt
    baseline = np.median(filtered[(t > a-.0035) & (t < a-.0005)])
    onset = result["audio_latest_scope_s"]
    fig, axes = plt.subplots(3, 1, figsize=(14, 10),
                             height_ratios=(1.2, 2.4, 2.4), layout="constrained")
    ruler = axes[0]
    timing_ruler(ruler, result)
    ruler.set(ylim=(0, 1), yticks=[], xlabel="相对首次 B 扫描窗口起点（ms）")
    ruler.spines["left"].set_visible(False)
    ruler.set_title("联合计时标尺（不占用波形电压轴）")
    left = result["conditional_closure_earliest_scope_s"]-.00015
    right = min(len(ch2)*dt, onset+.001)
    zoom_left, zoom_right = max(left, onset-.0004), min(right, onset+.0006)
    for ax, start, stop, title in (
            (axes[1], left, right, "CH2 模拟输出：完整计时间隔与起音"),
            (axes[2], zoom_left, zoom_right, "CH2 起音局部放大（实际电压，未归一化）")):
        raw_envelope(ax, ch2, dt, start, stop, begin, 1000, baseline)
        mask = (t > start) & (t < stop)
        ax.plot((t[mask]-begin)*1000, filtered[mask]-baseline, color="#087f8c", lw=1,
                label="50 kSa/s FIR 波形（已扣基线，仅供对照）")
        ax.axhline(.015, color="#b0283c", ls=":", label="正负 15 mV 参考线")
        ax.axhline(-.015, color="#b0283c", ls=":")
        ax.axvline(0, color="#b0283c", ls="--", lw=1)
        ax.axvline((onset-begin)*1000, color="#087f8c", ls="--", lw=1)
        ax.set(xlim=((start-begin)*1000, (stop-begin)*1000),
               title=title, xlabel="相对首次 B 扫描窗口起点（ms）", ylabel="CH2 电压（V）")
        ax.grid(alpha=.18)
    axes[1].legend(loc="upper left", ncol=3, fontsize=8)
    fig.savefig(output / "joint_audio.png", dpi=160)
    fig.savefig(output / "joint_audio.svg")
    plt.close(fig)

    from latency_budget_report import lookup, section, joint_display
    profile = lookup(trial, result) if result["conditional_upper_ms"] is None else {
        "status": "unmatched", "reason": "本报告使用人工填写预算，未自动叠加批次经验余量。"}
    result["batch_budget_evidence"] = profile
    display = joint_display(result, profile)
    verdict = display["verdict"]
    delay = (onset-begin)*1000
    timing = display["timing"]
    latest = max(evidence["sensitivities"], key=lambda s: s.get(
        "onset_scope_s", s.get("onset_from_A_ms", 0)))
    from polyphony_acceptance.report_chinese import display_value
    from latency_waveforms import confirmation_description
    latest_text = (f'{display_value("method", latest["method"])}，'
                   f'{latest["rate_Hz"]:.0f} Sa/s，{latest["threshold_mV"]:.0f} mV，'
                   + confirmation_description(latest))
    midwindow = result.get("b_midwindow_contact")
    midwindow_html = ""
    contact = result.get("initial_a_contact_transient")
    if contact and contact.get("fragment_interval"):
        render_initial_a_fragments(output, trial, data, result)
        midwindow_html += (
            '<h2>首次 A 碎片区间证据</h2>'
            f'<p>保留 {len(contact["events"])} 个前置数字列低片段，'
            f'最长 {max(event["width_us"] for event in contact["events"]):.4f} µs。'
            + html.escape(contact["policy"]) +
            '这不是放宽通用毛刺阈值，也没有跳过 B 接触。'
            '模拟与数字波形允许存在已记录的阈值差和同步残差，不声称逐采样点完全一致。</p>'
            '<img src="initial_a_fragments.png" alt="首次A碎片的原始模拟与数字证据">')
    if result.get("previous_a_contact"):
        render_previous_a(output, trial, data, result)
        previous = result["previous_a_contact"]
        midwindow_html += (
            '<h2>前帧 A 部分接触证据</h2>'
            f'<p>单独保留 {len(previous["events"])} 段数字列低及对应原始模拟波形。'
            + html.escape(previous["policy"])
            + '首次部分接触不是静止段，也没有被替换成后一个完整接触。'
            '下图蓝色 B 范围只要求排除带以外的内部列高，边界不宣称精确物理闭合。</p>'
            '<img src="previous_a_contact.png" alt="前帧A部分接触的原始模拟及行列证据">')
    if midwindow:
        render_midwindow(output, trial, data, result)
        witness = (
            f'首次接触含 {len(midwindow["raw_low_segments"])} 段原始列低（包含同期 A）；'
            '原始片段全部保留。仅该帧以最外侧起止沿同步，不将内部片段当作精确同步边沿；'
            '模拟 B 核心累计高段不超过 1 µs，末尾稳定低段已独立核对。'
            if midwindow["model"] == "initial_b_fragment_interval_v1" else
            f'首次B含 {len(midwindow["raw_low_segments"])} 段原始列低，'
            '末尾短低独立保留；它不参与共同列同步，模拟先高后低及低段尾沿已核对。'
            if midwindow["model"] == "short_initial_b_tail_v1" else
            '已核对原始数字内部只有一个低段，以及示波器阈值两侧的独立高段、低段。')
        midwindow_html += (
            '<h2>首次 B 中途导通证据</h2><p>'
            f'末尾稳定列低段始于该 B 窗口起点后 {midwindow["column_onset_from_b_start_us"]:.4f} µs，'
            '保持到内部末尾；随后三个完整 B 内部窗口列低。'
            + witness +
            '红色虚线为观测列低段起点，不是精确物理闭合时刻；计时零点仍取更早的窗口起点，'
            '扫描余量仍从前一 B 窗口起点计算，不通过跳过部分窗口来缩短结果。</p>'
            '<img src="b_midwindow.png" alt="首次 B 中途导通的原始模拟电压及行列证据">')
    rows = [
        ("联合结果", verdict),
        ("数据来源", "逻辑分析仪：A 行、B 行、列；示波器：列信号与 DAC 模拟输出"),
        ("两台仪器对齐依据", "同一次按压的共同列信号边沿拟合"),
        ("对齐前提", result.get("alignment_anchor_assumptions", "旧版记录，见计算参数")),
        ("数字验证范围", (
            f'首个主列导通前固定 5 ms 至记录末尾；此前 {result["measurement_window"]["excluded_duration_s"]:.6f} s'
            ' 不用于本次扫描验证，原始 CSV 完整保留；不代表此前扫描无异常。'
            if result.get("measurement_window") else "见本次计算参数")),
        ("B 定位方式", "直接检查 B 行内部窗口与列持续低，不要求 5 个 A 单触点脉冲"
         if result.get("scope_only_B_inference_required") is False else "见本次计算参数"),
        ("B 起点模型", (
            "首次B末尾短导通：短段不参与同步，独立模拟证据核对，随后三个B核心完整列低"
            if midwindow and midwindow["model"] == "short_initial_b_tail_v1" else
            "首次碎片化接触窗口：保留全部片段，末尾稳定列低，随后三个 B 内部窗口完整列低"
            if midwindow and midwindow["model"] == "initial_b_fragment_interval_v1" else
            "首次中途导通窗口：一次高到低保持至尾部，随后三个 B 内部窗口完整列低"
            if midwindow else "首次完整 B 内部窗口列低，连续保持至少三个窗口")),
        ("首次 B 中途导通", (
            f'窗口起点后 {midwindow["column_onset_from_b_start_us"]:.4f} µs 开始末尾稳定列低；'
            '保留该部分窗口为首次证据，未挪到下一帧；前一 B 起点的保守参考保持不变。'
            if midwindow else "未启用")),
        ("前帧 A 部分接触", (
            "自动按独立区间模型处理；原始接触保留、两帧B内部数字与模拟列高已核对；"
            "仅后续完整列起止沿同步，未跳过任何B导通窗口"
            if result.get("previous_a_contact") else "未启用")),
        ("图中时间零点", "首次出现 B 导通证据的扫描窗口起点；中途导通时不表示窗口全程列低；不是物理闭合瞬间"),
        ("图中终点", "示波器 CH2，各已分析方法及阈值的最晚起音"),
        ("图中标注的间隔", f"{delay:.5f} ms（未加入扫描及误差余量）"),
        ("最晚起音判据", latest_text),
        ("含扫描及误差处理的结果", timing),
        ("扫描周期实测范围", f'{result["scan_period_min_us"]:.4f}～{result["scan_period_max_us"]:.4f} µs'),
        ("扫描窗口保守余量", f'{result["maximum_scan_allowance_us"]:.4f} µs（包含一帧及当前 B 行窗口）'),
        ("共同列信号拟合最大残差", f'{result["alignment_max_residual_us"]:.4f} µs'),
        ("首次 A 接触瞬态", (
            f'单独归类 {len(result["initial_a_contact_transient"]["events"])} 个短低段；'
            '仅在首次 A 独占窗口内，不是丢弃 B 异常；紧接 B 内部已确认列高。'
            '首次下降沿按 A 窗口区间约束，不作为精确同步边沿；首次上升沿及后续全部起止沿仍参与拟合。'
            f'首次下降沿时刻差 {result["initial_a_contact_transient"]["first_start_difference_us"]:.4f} µs，'
            '不是 B 延迟误差或物理闭合时间。'
            if result.get("initial_a_contact_transient") else
            "未启用 A 区间模型；首次 B 碎片帧仅外侧起止沿配对，其他帧完整起止沿逐一配对"
            if midwindow and midwindow["model"] == "initial_b_fragment_interval_v1" else
            "未启用；共同列全部完整起止沿逐一配对")),
        ("错帧配对复核", "、".join(
            f'{v["pulse_index_shift"]:+d} 帧残差 {v["max_residual_us"]:.3f} µs'
            + ("，与已观测按下前静止段冲突" if v.get("conflicts_with_observed_prepress_quiet") else "")
            for v in result.get("alignment_rejected_shift_candidates", []))
         + "；错帧配对须残差超限或与已观测静止段冲突，不能仅凭周期波形宣称唯一同步"),
        ("行边界处理", result.get("boundary_policy", "旧版记录，未记录边界处理策略")),
        ("边界排除带", f'{result.get("boundary_exclusion_us", 0):.4f} µs（分析策略，不是硬件误差保证）'),
        ("计入上界的额外边界余量", f'{result.get("boundary_additional_margin_us", 0):.4f} µs（两侧排除带合计）'),
        ("边沿短跳变排除数", "、".join(f'{k}：{v}' for k, v in
                                     result.get("excluded_short_low_pulses", {}).items())),
        ("末尾处理", "逻辑末尾不完整低脉冲已排除；完整脉冲须覆盖示波器和起音"
         if result.get("logic_trailing_incomplete_pulse_omitted") else "未排除逻辑末尾低脉冲"),
        ("采集前导段", f'{result.get("startup_prefix", {}).get("excluded_duration_us", 0):.3f} µs；'
         "可排除≤440 µs 的首帧异常（每路最多一个≤60 µs行主脉冲，列仅允许≤1 µs短低脉冲）；"
         "其后仍须有至少两个周期的按下前静止段"),
        ("前导段排除依据", result.get("startup_prefix", {}).get(
            "reason", "无首帧宽度/周期排除；如有前导短跳变，参数见 analysis.json")),
        ("前导短低脉冲排除数", "、".join(f"{k}：{v}" for k, v in
                  result.get("startup_prefix", {}).get("excluded_short_low_pulses", {}).items())),
        ("前导段排除脉冲明细", "；".join(
            f'{channel}：{pulse["start_s"]:.9f}～{pulse["end_s"]:.9f} s，'
            f'低宽 {pulse["width_us"]:.3f} µs'
            for channel, values in result.get("startup_prefix", {}).get("excluded_pulses", {}).items()
            for pulse in values) or "无首帧主脉冲排除"),
        ("数字采样分辨率", f'{result["digital_resolution_us"]:.4f} µs'),
        ("示波器采样间隔", f'{result["scope_sample_interval_us"]:.4f} µs'),
        ("滤波与起音分析余量", display["allowance"]),
        ("示波器时基误差", display["clock"]),
    ]
    body = ('<p class="meta">同一次按压的行列联合验证。图像由保存的原始数据绘制，'
            '不是仪器屏幕截图。工具结论不等于比赛验收。</p>'
            '<h2>测量结果与计时口径</h2><table><thead><tr><th>项目</th><th>结果</th></tr></thead><tbody>'
            + "".join(f"<tr><td>{html.escape(k)}</td><td>{html.escape(v)}</td></tr>" for k, v in rows)
            + '</tbody></table>'
            + section(profile, output)
            + '<h2>经验余量口径</h2>'
            '<p>经验性分析余量不是校准确认的误差上限；滤波使用的未来样本范围'
            '不直接当作等量计时误差。现有结果已取各分析配置的最晚起音，'
            '批量评估时应避免重复累加已覆盖的方法差异。</p>'
            + '<p><strong>起音判据限制：</strong>当前按名义100 µs所对应的连续超阈值采样点数确认。'
            '采样点首末跨度可能不足100 µs，点与点之间也可能跌回阈值或跨越零点；'
            '不等价于真实模拟信号全程持续超阈值。重采样相位敏感性须独立检查，'
            '不能直接解释为FPGA内部硬件抖动。</p>'
            + '<p><strong>结论边界：</strong>' + html.escape(display["caveat"]) + '</p>'
            + '<h2>逻辑分析仪：B 扫描窗口证据</h2>'
            '<img src="b_window.png" alt="逻辑分析仪 A/B 行和列波形，以及 B 扫描窗口到最晚起音的计时标尺">'
            + midwindow_html +
            '<h2>示波器：联合时间轴上的模拟起音</h2>'
            '<p>终点采用各方法的最晚起音，不一定是图中 50 kSa/s、15 mV 曲线的首次越阈值位置。'
            '图中零点与仅示波器分析报告的“推断 B 参考”不同，两个间隔不能直接混用。</p>'
            '<img src="joint_audio.png" alt="以逻辑分析仪 B 扫描窗口为时间零点的 CH2 波形与计时箭头">'
            '<h2>判定条件与限制</h2>'
            '<p>起点口径为 B 持续有效导通。A/B/列为低有效、固定八行扫描；'
            '常规模型要求 B 行内部完整列低；首次中途导通另按独立判据检查：'
            'A 尾部已经退出、原始数字内部恰有一次高到低且保持至尾部、模拟列有对应高低证据，'
            '随后三个 B 内部窗口完整列低；接通后又断开或更晚部分窗口不接受。'
            '不跳过首次部分导通窗口，不将它挪到下一完整窗口计算。'
            '普通边沿短跳变仍只在固定边界排除带内处理，'
            '另对首次 A 独占窗口内、每段不超过 1 µs 的接触短跳变单独归类；'
            '若使用首次 A 碎片区间模型，1～10 µs 前置片段必须全部保留于同一 A 独占窗口，'
            '并核对原始模拟列低及紧接 B 内部的模拟列高；不用于排除其它窗口的异常。'
            '此时首次下降沿只提供 A 窗口区间约束，且模拟列早期低段须处于同一 A 窗口内、'
            '首次上升沿和后续全部起止沿仍严格对齐，紧接 B 内部必须列高。'
            '这些分类不推断电气成因，不接受 B 内部重新断开或其它窗口异常。'
            '不会将 A 行低电平尾部与 B 行的边界重叠当成 B 导通。'
            '边界排除带不是硬件保证，已将两侧排除带合计作为额外不确定性计入结果。'
            '两份记录须人工确认同一次动作。观察到的是首次 B 行与列同时有效的窗口，'
            '并非精确的 FPGA 输入采样边沿或物理闭合瞬间。先前短暂抖动不在此起点口径内。</p>'
            '<p>条件性计算从前一 B 行窗口起点取更早的闭合参考，再计入同步、采样及填写的误差余量；'
            '因此不能把图中箭头数值直接当作物理闭合到模拟起音的最坏延迟。</p>'
            '<p><strong>结果依赖人工填写误差预算及当前记录；不是严格计量上界，'
            '不证明全键、最坏情况或无抖动。最大观测扫描周期不能单独证明未来扫描不会暂停。</strong></p>'
            '<h2>固件与原始证据</h2>')
    common = result.get("common_recording_window")
    if common:
        body += (
            '<h2>共同记录范围与后段异常</h2>'
            '<p>完整数字记录因列脉冲异常未通过；本报告仅验证完整示波器记录及固定尾部保留段，'
            '不是整条逻辑记录无异常的证明。首次触点和起音过程均保留，未按起音位置裁剪。</p>'
            f'<p>最终同步确认示波器终点后仍保留 {common["retained_tail_guard_us"]:.3f} µs；'
            f'其后 {common["excluded_tail_duration_s"]*1000:.3f} ms 数字后段未作扫描验收。'
            '完整数字数据仍在 logic.csv 中，未删除。</p>'
            '<table><tr><th>后段异常在原数字时间轴的位置 s</th><th>低脉冲宽度 µs</th></tr>'
            + "".join(
                f'<tr><td>{event["start_s"]:.9f}</td><td>{event["width_us"]:.3f}</td></tr>'
                for event in common["excluded_intermediate_events"]+common.get("excluded_short_events", []))
            + '</table><p>窗口内仍使用原有同步、扫描、B起点及模拟起音检查；误差预算未核实仍不判定达标。</p>')
    prefix = result.get("measurement_window", {}).get("initial_low_prefix")
    if prefix:
        body += (
            '<h2>数字记录起始截断低前缀</h2>'
            f'<p>记录起始至 {prefix["end_s"]:.9f} s 出现截断列低及短片段，'
            f'限制在一个实测扫描周期内；与本次首个主列脉冲之间列高静止 '
            f'{prefix["quiet_until_first_main_s"]*1000:.3f} ms。'
            '本次仍验证首个主列前固定5ms至共同记录末端；'
            '完整前缀未删除，不声称更早时段没有触点动作，也不将该前缀作为本次计时起点。'
            '已独立核对完整示波器记录起点晚于该前缀。</p>')
    version = result["version_user_recorded"]
    scope_link = (
        f'<a href="{html.escape(result["scope_evidence_report"], quote=True)}">'
        '仅示波器分析与方法敏感性明细</a> · ' if result.get("scope_evidence_report") else "")
    body += (f'<p class="meta">固件人工记录（未读回 FPGA）：{html.escape(str(version.get("bitstream_path", "未记录")))}'
             f'<br>SHA256：{html.escape(str(version.get("sha256", "未记录")))}</p>'
             '<p><a href="analysis.json">计算参数与哈希</a> · <a href="logic.csv">逻辑分析仪数字原始数据</a> · '
             + scope_link +
             f'<a href="{html.escape(relative_link(screen_file(trial, "latency"), output), quote=True)}">'
             '示波器原屏</a></p>')
    if result.get("audio_evidence"):
        body += ('<h2>独立模拟起音分析明细</h2><p>起音搜索从首个列导通之后开始，'
                 '不是先猜 B 再寻找声音；若声音早于已定位 B 窗口，联合验证拒绝输出可用结果。'
                 '两种滤波、三种采样率、三种阈值共 18 项，不依赖仅示波器 B 推断报告。</p>'
                 '<table><tr><th>方法</th><th>Sa/s</th><th>阈值 mV</th>'
                 '<th>相对首个列导通的起音 ms</th></tr>'
                 + "".join(
                     f'<tr><td>{html.escape(display_value("method", s["method"]))}</td>'
                     f'<td>{s["rate_Hz"]:.0f}</td><td>{s["threshold_mV"]:.0f}</td>'
                     f'<td>{s["onset_from_contact_ms"]:.5f}</td></tr>'
                     for s in evidence["sensitivities"]) + '</table>')
    (output / "report.html").write_text(page("行列联合延迟验证："+verdict, body), encoding="utf-8")


def _analyze(trial, csv_path, names, allowance_us, clock_ppm, confirmed=False,
             sample_rate_hz=None, observation_only=False, previous_a=False,
             short_b=False, initial_a_fragments=False, context=None):
    if not confirmed:
        raise ValueError("必须人工确认同一次单键按压、按下前静止段、接线及 B 持续有效导通的起点口径。")
    if (not np.isfinite([allowance_us, clock_ppm]).all()
            or min(allowance_us, clock_ppm) < 0
            or (not observation_only and min(allowance_us, clock_ppm) == 0)):
        raise ValueError("额外分析余量和示波器时基误差必须填写有限正数，不能默认为零。")
    from latency_waveforms import load, onsets
    from scope_column_pulses import extract
    trial, csv_path = Path(trial), Path(csv_path)
    context = {} if context is None else context
    if "data" not in context:
        context["data"] = read_csv(csv_path, names)
    data = context["data"]
    try:
        validation_data, window_policy = measurement_window(
            data, allow_previous_a_contact=previous_a,
            allow_initial_a_fragments=initial_a_fragments)
    except ValueError as original_error:
        try:
            validation_data, window_policy = measurement_window(
                data, allow_initial_prefix=True, allow_previous_a_contact=previous_a,
                allow_initial_a_fragments=initial_a_fragments)
        except ValueError:
            raise original_error
    if "scope" not in context:
        context["scope"] = load(trial)
    (column, ch2), dt, loaded_evidence = context["scope"]
    evidence = dict(loaded_evidence)
    if "scope_t" not in context:
        context["scope_t"] = np.arange(len(column))*dt
    scope_t = context["scope_t"]
    if "extracted" not in context:
        context["extracted"] = extract(column, dt)
    starts, stops, censored = context["extracted"]
    previous = previous_a_contact(validation_data) if previous_a else None
    if previous_a:
        if not previous:
            raise ValueError("不存在可由前帧A独立模型处理的接触。")
        # Only one extra analog pulse, in the immediately preceding A frame,
        # may precede the first full digital A. Its raw samples are checked
        # after strict all-edge alignment, not removed from the evidence.
        width = np.diff(previous["first_full_a_column_logic_s"])[0]
        resolution = 1/sample_rate_hz if sample_rate_hz else float(np.max(np.diff(data[:, 0])))
        limit = 2e-6+2*resolution+2*dt
        if abs((stops[0]-starts[0])*dt-width) > limit:
            if len(starts) < 2 or abs((stops[1]-starts[1])*dt-width) > limit:
                raise ValueError("前帧A模型无法唯一确定首个完整模拟A脉冲。")
            previous["extra_extracted_analog_pulse_scope_s"] = [
                float(starts[0]*dt), float(stops[0]*dt)]
            starts, stops = starts[1:], stops[1:]
    if column[0] < 1.5:
        raise ValueError("示波器列信号从低电平开始，无法确认首次列导通。")
    short = (stops-starts)*dt <= 10e-6
    if np.any(short) and not short_b:
        events = [dict(start_scope_s=float(s*dt), end_scope_s=float(e*dt),
                       width_us=float((e-s)*dt*1e6),
                       from_first_main_ms=float((s-starts[0])*dt*1000))
                  for s, e in zip(starts[short], stops[short])]
        raise SignalEvidenceError(
            "示波器列含 1～10 µs 的独立脉冲，不能忽略后确定首次导通。"
            f"共{len(events)}段，相对首个主列下降沿位于 "
            f"{min(x['from_first_main_ms'] for x in events):.6f}～"
            f"{max(x['from_first_main_ms'] for x in events):.6f} ms；"
            "这不一定发生在起点附近，也不是延迟超标结论。"
            "仅在独立A/B窗口模型能解释全部短段时继续分析。",
            dict(category="scope_independent_short_pulses", events=events,
                 action="保留原始记录；不能删除记录中段短脉冲来通过验证。"
                        "已有足够有效次数时无需为了此无效记录重复测量。"))
    a = float(starts[0]*dt)  # First observed column contact, not necessarily A.
    if "raw_scope_pulses" not in context:
        context["raw_scope_pulses"] = pulses(scope_t, column < 1.5, trim=True)
    raw_s, raw_e = context["raw_scope_pulses"]
    prior = (raw_s < a-2e-6) & (raw_e-raw_s > 1e-6)
    if prior.any() and not previous_a and not initial_a_fragments:
        events = [dict(start_s=float(s), end_s=float(e),
                       width_us=float((e-s)*1e6),
                       before_first_main_us=float((a-s)*1e6))
                  for s, e in zip(raw_s[prior], raw_e[prior])]
        raise SignalEvidenceError(
            "首个主列脉冲之前存在较长导通，不能作为无导通静止段对齐。"
            f"共 {len(events)} 段，最长 {max(p['width_us'] for p in events):.3f} µs，"
            f"最早位于主脉冲前 {events[0]['before_first_main_us']:.3f} µs。"
            "需核对前一帧A/B交界和原始模拟列；不能直接忽略，也不代表延迟超标。",
            dict(category="prior_analog_column_contact", channel="示波器列信号",
                 first_main_s=a, events=events))
    if previous_a:
        early = raw_s < a-2e-6
        if not early.any():
            raise ValueError("前帧A接触缺少原始模拟列低。")
        a = float(raw_s[early][0])
    onset_cache = context.setdefault("onsets", {})
    if a not in onset_cache:
        onset_cache[a] = onsets(ch2, dt, a)
    evidence.update(first_column_contact_scope_s=a, terminal_censored_pulse=censored,
                    sensitivities=onset_cache[a])
    audio_latest = max(s["onset_scope_s"] for s in evidence["sensitivities"])
    if stops[-1]*dt <= audio_latest+.0001:
        raise ValueError("完整列扫描证据未覆盖起音及 0.1 ms 确认区间。")
    def validate(fragmented=False):
        options = dict(scope_intervals=(starts*dt, stops*dt), first_contact_anchor=True)
        if previous_a:
            options["allow_previous_a_contact"] = True
        if short_b:
            options["allow_short_initial_b"] = True
        if initial_a_fragments:
            options["allow_initial_a_fragments"] = True
        if fragmented:
            options["allow_fragmented_initial_b"] = True
        common = None
        try:
            timing = verify(validation_data, scope_t, column, audio_latest,
                            allowance_us, clock_ppm, sample_rate_hz, **options)
        except SignalEvidenceError as error:
            bounded, common = common_scope_tail_window(
                validation_data, scope_t, (starts*dt, stops*dt), sample_rate_hz, error,
                **{k: v for k, v in options.items() if k != "scope_intervals"})
            timing = verify(bounded, scope_t, column, audio_latest,
                            allowance_us, clock_ppm, sample_rate_hz, **options)
            final_end = (scope_t[-1]-timing["alignment_offset_s"])/timing["alignment_scale"]
            guard = (common["validated_logic_end_s"]-final_end)*1e6
            if guard < 900:
                raise ValueError("最终同步未确认完整示波器记录及至少0.9ms尾部覆盖，不能排除数字后段。")
            common["retained_tail_guard_us"] = float(guard)
        return timing, common

    try:
        result, common_window = validate()
    except ValueError as original_error:
        try:
            result, common_window = validate(fragmented=True)
        except ValueError:
            raise original_error
    if window_policy.get("initial_low_prefix"):
        prefix = window_policy["initial_low_prefix"]
        scope_start_logic = -result["alignment_offset_s"]/result["alignment_scale"]
        if scope_start_logic <= prefix["end_s"]+result["alignment_fit_limit_us"]*1e-6/result["alignment_scale"]:
            raise ValueError("示波器完整记录仍覆盖起始低前缀，不能作为无关前段排除。")
        prefix["scope_record_start_logic_s"] = float(scope_start_logic)
    if short_b:
        contact = result["b_midwindow_contact"]
        if not contact or contact["model"] != "short_initial_b_tail_v1":
            raise ValueError("未完成首次B短尾独立验证。")
        short = (stops-starts)*dt <= 10e-6
        if np.count_nonzero(short) != 1:
            raise ValueError("模拟列不止一个独立短脉冲，不能归类为单次首次B短尾。")
        low, tail = contact["column_low_logic_s"]
        mapped = np.array([low, tail])*result["alignment_scale"]+result["alignment_offset_s"]
        if np.max(abs(np.array([starts[short][0], stops[short][0]])*dt-mapped)) > result["alignment_fit_limit_us"]*1e-6:
            raise ValueError("模拟独立短脉冲并非首次B短尾，不能忽略。")
    result.update(
        kind="joint_scan_latency", csv_columns=list(names),
        analysis_model_version=(
            "digital_rows_v12_initial_a_entry_fragments" if initial_a_fragments else
            "digital_rows_v10_short_initial_b" if short_b else
            "digital_rows_v9_previous_a_interval" if previous_a else
            "digital_rows_v8_bounded_recording"
            if window_policy.get("initial_low_prefix") or
            (common_window and common_window.get("error_category") == "unexplained_short_pulses") else
            "digital_rows_v7_initial_b_interval"
            if result["b_onset_model"] == "initial_b_fragment_interval_v1" else
            "digital_rows_v6_common_window" if common_window else "digital_rows_v5"),
        common_recording_window=common_window,
        scope_only_B_inference_required=False,
        measurement_window=window_policy,
        audio_evidence=evidence,
        logic_csv_sha256=hashlib.sha256(csv_path.read_bytes()).hexdigest(),
        raw_sha256=evidence["raw_sha256"], version_user_recorded=evidence["version_user_recorded"],
        raw_hashes_verified=True,
        same_press_and_wiring_user_confirmed=True,
        logic_sample_rate_hz_user_or_capture_recorded=sample_rate_hz,
        origin_definition="B 触点持续有效导通；不是包含抖动的第一次瞬时接触。",
    )
    if observation_only:
        result["unbudgeted_timing_envelope_ms"] = result.pop("conditional_upper_ms")
        result["conditional_upper_ms"] = None
        result["conditional_below_5ms"] = None
        result["error_budget_verified"] = False
    return result, data, ch2, dt, a


def recovery_candidates(data):
    """Select supported hypotheses from raw events, not the desired delay."""
    try:
        data, _ = measurement_window(
            data, allow_initial_prefix=True, allow_previous_a_contact=True,
            allow_initial_a_fragments=True)
    except ValueError:
        pass
    t, _, _, column = data.T
    rows = []
    for row in data[:, 1:3].T:
        start, end = pulses(t, row == 0, trim=True)
        keep = end-start > 10e-6
        rows.extend((start[keep], end[keep]))
    previous = previous_a_contact(data) is not None
    short_b = short_initial_b(t, column, *rows, 2e-6) is not None
    fragments = first_a_fragments(data) is not None
    candidates = []
    if previous:
        candidates.append(dict(previous_a=True))
    if short_b:
        candidates.append(dict(short_b=True))
    if previous and short_b:
        candidates.append(dict(previous_a=True, short_b=True))
    if fragments:
        candidates.append(dict(initial_a_fragments=True))
    if fragments and short_b:
        candidates.append(dict(initial_a_fragments=True, short_b=True))
    return candidates


def analyze(trial, csv_path, names, allowance_us, clock_ppm, confirmed=False,
            sample_rate_hz=None, observation_only=False):
    args = (trial, csv_path, names, allowance_us, clock_ppm, confirmed,
            sample_rate_hz, observation_only)
    context = {}
    try:
        return _analyze(*args, context=context)
    except ValueError as original_error:
        if not confirmed:
            raise
        data = context.get("data")
        if data is None:
            data = read_csv(csv_path, names)
            context["data"] = data
        if confirmed:
            mismatch = row_column_mismatch(data)
            if mismatch:
                phase = mismatch["column_after_A_us"]["median"]
                raise SignalEvidenceError(
                    f"行列对应未验证：{mismatch['column_main_pulses']} 个完整列主脉冲中，"
                    f"所测 A、B 行内部均未出现列导通；列下降沿位于 A 行之后约 {phase:.3f} µs。"
                    "本记录缺少目标键 B 行导通证据，不是消抖或延迟超标结论。"
                    + mismatch["action"], mismatch) from original_error
        attempts = [dict(options={}, reason=str(original_error))]
        blocking_error = original_error
        for options in recovery_candidates(data):
            try:
                outcome = _analyze(*args, **options, context=context)
                outcome[0]["automatic_handling"] = dict(
                    selected_options=options, preceding_attempts=attempts,
                    cached_raw_and_onsets=True,
                    policy="仅按原始波形选独立证据模型；不改计时起点、阈值或误差预算。")
                return outcome
            except ValueError as error:
                blocking_error = error
                attempts.append(dict(options=options, reason=str(error),
                                     details=getattr(error, "details", None)))
        blocking_error.analysis_attempts = attempts
        if blocking_error is original_error:
            raise original_error
        blocking_error.initial_analysis_error = str(original_error)
        raise blocking_error from original_error


def generate(trial, csv_path, names, allowance_us, clock_ppm, confirmed=False,
             sample_rate_hz=None, observation_only=False):
    trial, csv_path = Path(trial), Path(csv_path)
    result, data, ch2, dt, a = analyze(
        trial, csv_path, names, allowance_us, clock_ppm, confirmed,
        sample_rate_hz, observation_only)
    evidence = result["audio_evidence"]
    report_base = report_folder(trial, "latency")
    output = report_base / "scan_validation"
    output.mkdir(parents=True, exist_ok=True)
    # Preserve every imported record/report without replacing earlier verification.
    number = 1
    while (output / f"verification_{number:03}").exists():
        number += 1
    output = output / f"verification_{number:03}"
    output.mkdir()
    (output / "logic.csv").write_bytes(csv_path.read_bytes())
    (output / "analysis.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    render_report(output, trial, data, result, evidence, ch2, dt, a)
    (output / "analysis.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    return output / "report.html"


def generate_observation(trial, csv_path, sample_rate_hz):
    return generate(trial, csv_path, ("Time [s]", "Channel 0", "Channel 1", "Channel 2"),
                    0., 0., True, sample_rate_hz, observation_only=True)

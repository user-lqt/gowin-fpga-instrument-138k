#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成音频核心的查找表 RTL(A0/A1)。

每次运行**覆盖**以下文件(它们由本脚本生成,不要手改):
    rtl/audio_core/note_to_fc.v   128 项 MIDI 音符号 -> 32 位相位增量
    rtl/audio_core/wavetable.v    4096 点 signed 16 bit 正弦表

定点假设(已冻结于 rtl/common/event_defs.vh):
    Fs = 48000 Hz,相位累加器 32 bit
    fc = round(f_note * 2**32 / Fs)
"""

import math
import os

FS = 48000
ACC_BITS = 32
WT_ADDR_BITS = 12
WT_POINTS = 1 << WT_ADDR_BITS
WT_SCALE = 32767.0

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_DIR = os.path.join(ROOT, "rtl", "audio_core")


def _write(name, lines):
    path = os.path.join(OUT_DIR, name)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote %s (%d lines)" % (path, len(lines)))


def gen_note_to_fc():
    L = []
    L.append("//=============================================================================")
    L.append("// note_to_fc.v -- MIDI 音符号 -> 32 位相位增量(频率控制字 FC)")
    L.append("//")
    L.append("// 【自动生成,请勿手改】由 sim/audio_core_tb/gen_tables.py 生成。")
    L.append("//")
    L.append("//   FC = round(f_note * 2^32 / Fs),Fs = 48000 Hz,相位累加器 32 bit。")
    L.append("//   查表法:任意音符号的频率误差 < 0.001 音分(仅受 FC 取整限制)。")
    L.append("//   MIDI 标准:A4 = 440 Hz 对应 note_id = 69。")
    L.append("//=============================================================================")
    L.append('`include "event_defs.vh"')
    L.append("")
    L.append("module note_to_fc (")
    L.append("    input  wire [6:0]  note_id,")
    L.append("    output reg  [31:0] fc")
    L.append(");")
    L.append("    always @(*) begin")
    L.append("        case (note_id)")
    for n in range(128):
        f = 440.0 * (2.0 ** ((n - 69) / 12.0))
        fc = int(round(f * (1 << ACC_BITS) / FS)) & 0xFFFFFFFF
        L.append("            7'd%3d: fc = 32'd%10d;   // %9.3f Hz" % (n, fc, f))
    L.append("            default: fc = 32'd0;")
    L.append("        endcase")
    L.append("    end")
    L.append("endmodule")
    _write("note_to_fc.v", L)


def gen_wavetable():
    L = []
    L.append("//=============================================================================")
    L.append("// wavetable.v -- 正弦波表,4096 点,signed 16 bit")
    L.append("//")
    L.append("// 【自动生成,请勿手改】由 sim/audio_core_tb/gen_tables.py 生成。")
    L.append("//")
    L.append("//   地址取相位累加器高 12 位;幅度对称满量程 +-32767(留 1 LSB 防削波)。")
    L.append("//=============================================================================")
    L.append('`include "event_defs.vh"')
    L.append("")
    L.append("module wavetable (")
    L.append("    input  wire                clk,")
    L.append("    input  wire [%d:0]         addr," % (WT_ADDR_BITS - 1))
    L.append("    output reg  signed [15:0]  dout")
    L.append(");")
    L.append("    reg signed [15:0] rom [0:%d];" % (WT_POINTS - 1))
    L.append("")
    L.append("    initial begin")
    for i in range(WT_POINTS):
        v = int(round(WT_SCALE * math.sin(2.0 * math.pi * i / WT_POINTS)))
        if v < 0:
            L.append("        rom[%4d] = -16'sd%5d;" % (i, -v))
        else:
            L.append("        rom[%4d] =  16'sd%5d;" % (i, v))
    L.append("    end")
    L.append("")
    L.append("    always @(posedge clk) dout <= rom[addr];")
    L.append("endmodule")
    _write("wavetable.v", L)


if __name__ == "__main__":
    gen_note_to_fc()
    gen_wavetable()
    print("done.")

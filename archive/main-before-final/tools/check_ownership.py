#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_ownership.py —— 本地自检：确认你的改动没有越界到别人的目录。

用法：
    python tools/check_ownership.py A        # 检查 A 的改动是否越界
    python tools/check_ownership.py B
    python tools/check_ownership.py C
    python tools/check_ownership.py A --staged   # 只检查已 git add 的内容

判定方式：以 origin/main（或本地 main）为基线，列出改动文件，
逐个比对其所属目录是否在当前成员的权限范围内。

不依赖任何第三方库。
"""

import os
import subprocess
import sys

OWNERSHIP = {
    'A': {
        'allowed': ['rtl/audio_core/', 'sim/audio_core_tb/', 'evidence/', 'waveforms/'],
        'name': '成员 A · 音频合成与音质优化',
    },
    'B': {
        'allowed': ['rtl/input/', 'rtl/ui/', 'sim/input_ui_tb/', 'evidence/', 'waveforms/'],
        'name': '成员 B · 演奏输入与参数界面',
    },
    'C': {
        'allowed': ['rtl/system/', 'rtl/common/', 'sim/system_tb/', 'project/',
                    'constraint/', 'docs/', 'tools/', 'README.md',
                    'evidence/', 'waveforms/'],
        'name': '成员 C · 音频输出与 FPGA 系统平台',
    },
}

ALWAYS_OK_PREFIXES = ('.gitignore', '.gitattributes')


def run(args):
    r = subprocess.run(args, capture_output=True, text=True)
    return r.returncode, (r.stdout or '').strip(), (r.stderr or '').strip()


def baseline_ref():
    for ref in ('origin/main', 'main', 'HEAD'):
        code, out, _ = run(['git', 'rev-parse', '--verify', '--quiet', ref])
        if code == 0 and out:
            return ref
    return None


def changed_files(staged_only):
    ref = baseline_ref()
    if ref is None:
        return []
    if staged_only:
        _code, out, _err = run(['git', 'diff', '--cached', '--name-only'])
    else:
        code, out, _err = run(['git', 'diff', '--name-only', ref])
        if code != 0 or not out:
            code2, out2, _err2 = run(['git', 'status', '--porcelain'])
            out = '\n'.join(line[3:] for line in out2.splitlines()) if code2 == 0 else out
    return [f for f in out.splitlines() if f.strip()]


def main():
    if len(sys.argv) < 2 or sys.argv[1].upper() not in OWNERSHIP:
        print(__doc__)
        print('可用的成员代号：A / B / C')
        return 2

    who = sys.argv[1].upper()
    staged_only = '--staged' in sys.argv
    cfg = OWNERSHIP[who]

    files = changed_files(staged_only)
    if not files:
        print('没有检测到改动（基线对比为空）。')
        return 0

    bad = []
    for f in files:
        if f.startswith(ALWAYS_OK_PREFIXES):
            continue
        if not any(f.startswith(p) for p in cfg['allowed']):
            bad.append(f)

    print('成员：%s' % cfg['name'])
    print('允许目录：%s' % ', '.join(cfg['allowed']))
    print('检测到改动 %d 个文件。' % len(files))
    print()

    if bad:
        print('❌ 越界文件（请撤销改动或改为提交接口变更说明）：')
        for f in bad:
            print('   - %s' % f)
        print()
        print('撤销单个文件： git checkout -- <文件>')
        return 1

    print('✅ 全部改动都在你的权限范围内。')
    return 0


if __name__ == '__main__':
    sys.exit(main())

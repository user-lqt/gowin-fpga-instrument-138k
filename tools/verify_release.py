"""Read-only final-release verification. Never invokes Gowin or programs hardware."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(source=None):
    manifest = json.loads((ROOT / 'release/manifest.json').read_text(encoding='utf-8'))
    files = {**manifest['files'], **manifest['companion_files']}
    for relative, expected in files.items():
        path = ROOT / relative
        if not path.is_file() or sha(path) != expected:
            raise ValueError('Missing or changed release file: ' + relative)
    print(f'PASS byte integrity: {len(files)} final and companion files')
    project = ROOT / 'final/project/integrated_instrument_64'
    entry = project / 'integrated_instrument_64.gprj'
    count = 0
    for f in ET.parse(entry).iter('File'):
        relative = f.attrib['path']
        path = (project / relative).resolve()
        if not path.is_relative_to(project.resolve()) or not path.is_file():
            raise ValueError('Missing/escaping project input: ' + relative)
        count += 1
    incdirs = [project / 'source/rtl' / x for x in ('common', 'input', 'ui/new_screen')]
    for path in (project / 'source').rglob('*'):
        if path.suffix not in ('.v', '.vh'):
            continue
        content = path.read_text(encoding='utf-8')
        for relative in re.findall(r'`include\s+"([^"]+)"', content):
            choices = [path.parent / relative, *[d / relative for d in incdirs]]
            if not any(p.is_file() and p.resolve().is_relative_to(project.resolve()) for p in choices):
                raise ValueError('Unresolved include: ' + str(path) + ': ' + relative)
        for relative in re.findall(r'\$readmem[hb]\s*\(\s*"([^"]+)"', content):
            p = project / relative
            if not p.is_file() or not p.resolve().is_relative_to(project.resolve()):
                raise ValueError('Missing/escaping ROM: ' + relative)
    print(f'PASS project/include/ROM closure: {count} listed inputs')
    bitstream = ROOT / manifest['selected_bitstream']
    if sha(bitstream) != manifest['selected_bitstream_sha256']:
        raise ValueError('Final bitstream mismatch')
    shipped_fs = sorted(p.relative_to(ROOT/'final').as_posix() for p in (ROOT/'final').rglob('*.fs'))
    if shipped_fs != [manifest['selected_bitstream'].removeprefix('final/')]:
        raise ValueError('Expected exactly one final programming bitstream: ' + repr(shipped_fs))
    print('PASS exactly one final bitstream:', sha(bitstream))
    if source:
        source = Path(source)
        expected = {x['path']: x['sha256'] for x in manifest['source_inventory']}
        actual = {p.relative_to(source).as_posix(): sha(p) for p in source.rglob('*') if p.is_file()}
        if expected != actual:
            different = sorted(k for k in expected.keys() | actual.keys() if expected.get(k) != actual.get(k))
            raise ValueError('Original folder changed: ' + repr(different))
        print(f'PASS original folder unchanged: {len(expected)} files')
    for doc in [ROOT/'README.md',*(ROOT/'docs').glob('*.md'),ROOT/'companion/README.md']:
        for relative in re.findall(r'\]\(([^)]+)\)', doc.read_text(encoding='utf-8')):
            if relative.startswith(('http:', 'https:', '#')):
                continue
            target=(doc.parent / relative.split('#')[0]).resolve()
            if not target.exists():
                raise ValueError('Broken doc link: ' + str(doc) + ' -> ' + relative)
    print('PASS current documentation links')
    return {'status':'PASS', 'checked_files':len(files), 'project_inputs':count,
            'selected_bitstream_sha256':sha(bitstream), 'synthesis_run':False,
            'place_and_route_run':False, 'programming_run':False,
            'source_snapshot_unchanged':bool(source)}


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', help='Optionally compare every file in original folder')
    parser.add_argument('--report', help='Optional JSON report output')
    args=parser.parse_args()
    try:
        result=verify(args.source)
        if args.report:
            output=Path(args.report);output.parent.mkdir(parents=True,exist_ok=True)
            output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    except Exception as exc:
        print('FAIL:',exc,file=sys.stderr)
        sys.exit(1)

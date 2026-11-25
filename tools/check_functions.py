#!/usr/bin/env python3
"""Check shell function ownership: no function is defined twice within a load set,
every bundled library is loaded by its entry, and the shared bootstrap stays identical."""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
START = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)')
BOOTSTRAP = re.compile(r'^# >>> proxyall bootstrap\n.*?^# <<< proxyall bootstrap\n', re.M | re.S)


def parses(text):
    result = subprocess.run(['bash', '-n'], input=text, capture_output=True, text=True)
    return result.returncode == 0 and not result.stderr.strip()


def functions(path):
    """Top-level function names; heredoc bodies are skipped by parsing each definition."""
    lines = path.read_text().split('\n')
    names, i = [], 0
    while i < len(lines):
        match = START.match(lines[i])
        if not match:
            i += 1
            continue
        end = i if parses(lines[i] + '\n') else None
        j = i + 1
        while end is None and j < len(lines):
            if lines[j][:1] in '})' and parses('\n'.join(lines[i:j + 1]) + '\n'):
                end = j
            j += 1
        if end is None:
            raise SystemExit(f'{path.name}:{i + 1}: cannot find the end of {match.group(1)}')
        names.append(match.group(1))
        i = end + 1
    return names


def sb_modules():
    text = (ROOT / 'sb.sh').read_text()
    def array(name):
        match = re.search(rf'^{name}=\((.*?)\)', text, re.M | re.S)
        if not match:
            raise SystemExit(f'sb.sh: {name} not found')
        return match.group(1).split()
    return array('SB_MODULES'), array('SB_COMPONENTS')


def bundle_files():
    text = (ROOT / 'proxyall').read_text()
    match = re.search(r'^PA_LIBS=\((.*?)\)', text, re.M | re.S)
    if not match:
        raise SystemExit('proxyall: PA_LIBS not found')
    return match.group(1).split()


def main():
    errors = []
    modules, components = sb_modules()
    load_sets = {
        'sb': ['lib/common.sh', 'lib/sni_router.sh', *(f'lib/{m}' for m in modules), 'sb.sh'],
        'deploy': ['lib/common.sh', 'lib/sni_router.sh', 'deploy.sh'],
    }
    load_sets['relay'] = load_sets['sb'] + ['lib/relay.sh']
    cache = {}
    for set_name, files in load_sets.items():
        owner = {}
        for name in files:
            if name not in cache:
                cache[name] = functions(ROOT / name)
            for function in cache[name]:
                if function in owner:
                    errors.append(f'{set_name}: {function} defined in {owner[function]} and {name}')
                owner[function] = name

    libs = sorted(p.name for p in (ROOT / 'lib').glob('*.sh'))
    expected = sorted(['common.sh', 'sni_router.sh', *modules, *components])
    if libs != expected:
        errors.append(f'lib/ files {libs} differ from sb.sh modules {expected}')
    bundle = bundle_files()
    if sorted(bundle) != libs:
        errors.append(f'proxyall PA_LIBS {sorted(bundle)} differ from lib/ files {libs}')
    for name in libs:
        if f'# PROXYALL_LIB={name}\n' not in (ROOT / 'lib' / name).read_text():
            errors.append(f'lib/{name}: missing "# PROXYALL_LIB={name}" marker')

    blocks = [BOOTSTRAP.search((ROOT / entry).read_text()) for entry in ('sb.sh', 'deploy.sh')]
    if not all(blocks) or blocks[0].group(0) != blocks[1].group(0):
        errors.append('sb.sh and deploy.sh bootstrap blocks differ')

    for error in errors:
        print(error)
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())

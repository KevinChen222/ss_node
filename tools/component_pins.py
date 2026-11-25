#!/usr/bin/env python3
"""Check the SHA-256 pins in proxyall for every bundled file, or refresh them with --write."""
import argparse
import hashlib
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def pins(installer_text):
    """Map each pin constant to its file: SB_SHA256/DEPLOY_SHA256 for the entries, and one
    constant per library in PA_LIBS, named after the file (sb_core.sh -> SB_CORE_SHA256)."""
    match = re.search(r'^PA_LIBS=\((.*?)\)', installer_text, re.M | re.S)
    if not match:
        raise ValueError('proxyall: PA_LIBS not found')
    mapping = {'SB_SHA256': 'sb.sh', 'DEPLOY_SHA256': 'deploy.sh'}
    for name in match.group(1).split():
        mapping[name[:-3].upper() + '_SHA256'] = f'lib/{name}'
    return mapping


def sync(root, write):
    installer = root / 'proxyall'
    original = data = installer.read_text()
    for key, name in pins(data).items():
        digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
        assignments = re.findall(rf'^{key}=.*$', data, re.M)
        if len(assignments) != 1 or not re.fullmatch(rf'{key}="[0-9a-f]{{64}}"', assignments[0]):
            raise ValueError(f'proxyall: expected one SHA-256 assignment for {key}')
        data = re.sub(rf'^{key}=.*$', f'{key}="{digest}"', data, flags=re.M)
    if data == original:
        return 0
    if write:
        installer.write_text(data)
    print('proxyall')
    return 0 if write else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true', help='update pins in the working tree')
    try:
        sys.exit(sync(ROOT, parser.parse_args().write))
    except (OSError, ValueError) as exc:
        sys.exit(str(exc))

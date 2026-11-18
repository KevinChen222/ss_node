#!/usr/bin/env python3
"""Check repository component pins, or refresh them with --write."""
import argparse
import hashlib
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
# Process dependencies before the scripts whose digests include their pins.
PINS = {
    'advanced_relay.sh': {'PARSER_SHA256': 'parser.sh'},
    'sb.sh': {'PARSER_SHA256': 'parser.sh', 'ADVANCED_RELAY_SHA256': 'advanced_relay.sh'},
    'proxyall': {'PARSER_SHA256': 'parser.sh', 'RELAY_SHA256': 'advanced_relay.sh',
                 'SB_SHA256': 'sb.sh', 'DEPLOY_SHA256': 'deploy.sh'},
}


def sync(root, write):
    pending = {}
    for name, pins in PINS.items():
        original = data = (root / name).read_bytes()
        for field, dependency in pins.items():
            source = pending[dependency] if dependency in pending else (root / dependency).read_bytes()
            digest = hashlib.sha256(source).hexdigest().encode()
            key = field.encode() + b'='
            assignments = re.findall(b'^' + key + b'.*$', data, re.M)
            if len(assignments) != 1 or not re.fullmatch(key + b'"[0-9a-f]{64}"', assignments[0]):
                raise ValueError(f'{name}: expected one SHA-256 assignment for {field}')
            data = re.sub(b'^' + key + b'.*$', key + b'"' + digest + b'"', data, flags=re.M)
        if data != original:
            pending[name] = data
    for name, data in pending.items():
        if write:
            (root / name).write_bytes(data)
        print(name)
    return 0 if write or not pending else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true', help='update pins in the working tree')
    try:
        sys.exit(sync(ROOT, parser.parse_args().write))
    except (OSError, ValueError) as exc:
        sys.exit(str(exc))

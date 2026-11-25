#!/usr/bin/env python3
"""Check YAML node names that also parse as scalars using mikefarah/yq v4."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get('TEST_YQ'), 'set TEST_YQ for real YAML name tests')
class YamlNames(unittest.TestCase):
    def exercise(self, entry, operations):
        for name in ('443', 'true', 'null'):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as work:
                path = Path(work, 'nodes.yaml')
                initial = {'proxies': [{'name': 'keep', 'port': 9443}],
                           'proxy-groups': [{'name': '节点选择', 'proxies': ['keep']}]}
                path.write_text(json.dumps(initial))
                script = r'''
source "$REPO/sb.sh" || exit 1
[ "$ENTRY" = sb.sh ] || source "$REPO/$ENTRY" || exit 1
YQ_BINARY=$TEST_YQ CLASH_YAML_FILE=$WORK/nodes.yaml RELAY_CLASH_YAML=$WORK/nodes.yaml
PROXYALL_WRITE_LOCK_FILE=$WORK/lock
''' + operations
                p = subprocess.run(['bash', '-e', '-c', script], capture_output=True, text=True,
                                   env=dict(os.environ, REPO=str(REPO), WORK=work, ENTRY=entry,
                                            NAME=name, NODE=json.dumps({'name': name, 'port': 8443})))
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
                load_added = json.loads(Path(work, 'added.json').read_text())
                self.assertEqual(load_added['proxies'][-1]['name'], name)
                self.assertCountEqual(load_added['proxy-groups'][0]['proxies'], ['keep', name])
                self.assertEqual(json.loads(Path(work, 'removed.json').read_text()), initial)

    def test_node_lookup_duplicate_and_removal(self):
        self.exercise('sb.sh', r'''
_add_node_to_yaml "$NODE"
[[ $(_get_proxy_field "$NAME" .port) == 8443 ]]
if _add_node_to_yaml "$NODE"; then exit 1; fi
"$YQ_BINARY" -o=json '.' "$CLASH_YAML_FILE" > "$WORK/added.json"
_remove_node_from_yaml "$NAME"
"$YQ_BINARY" -o=json '.' "$CLASH_YAML_FILE" > "$WORK/removed.json"
''')

    def test_relay_group_uses_string_names(self):
        self.exercise('lib/relay.sh', r'''
_add_node_to_relay_yaml "$NODE"
"$YQ_BINARY" -o=json '.' "$RELAY_CLASH_YAML" > "$WORK/added.json"
_remove_node_from_relay_yaml "$NAME"
"$YQ_BINARY" -o=json '.' "$RELAY_CLASH_YAML" > "$WORK/removed.json"
''')


if __name__ == '__main__':
    unittest.main()

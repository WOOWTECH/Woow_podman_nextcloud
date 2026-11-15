"""Exercise the real CLI with a private Podman double, including python -O."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TABLE = 'oc_sharing_share_recipients'
INDEX = 'uniq_734621b62ae63fdb4185a14495a838f'
DEFINITION = f'CREATE UNIQUE INDEX {INDEX} ON public.{TABLE} USING btree (share_id, recipient_class_id, recipient_value)'
PODMAN = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['FIXTURE'])
d = json.loads(p.read_text())
a = sys.argv[1:]
with p.with_suffix('.calls').open('a') as f: f.write(json.dumps(a)+'\n')
if 'occ' in a:
    command = a[a.index('occ')+1]
    if command == 'status': print(json.dumps({'versionstring': d.get('version', '35.0.3')}))
    elif command == 'config:app:get': print('1.0.5')
    elif command == 'db:schema:expected':
        print(json.dumps({d['table']: {'indexes': {d['table']+'_pkey': {'columns': ['id']},
              'uniq_734621b645af3a': {'columns': ['recipient_secret'], 'unique': True}}}}))
    elif command == 'db:schema:check':
        print(json.dumps([] if d.get('applied') else [{'table': d['table'], 'name': d['index'], 'type': 'unexpected_index'}]))
    else: sys.exit(91)
else:
    q = a[-1]
    if q.startswith('SELECT count(*) FROM oc_'): print(d.get('rows', 0))
    elif q.startswith('SELECT count(*) FROM pg_constraint'): print(0)
    elif q.startswith('SELECT indexdef'): print(d['definition'])
    elif q.startswith('SELECT indexname'): print(d['table']+'_pkey:primary\nuniq_734621b645af3a:unique')
    elif q.startswith('SELECT oid'): print('7:PRIMARY KEY (id)')
    elif q.startswith('BEGIN;'):
        d['applied'] = True
        p.write_text(json.dumps(d))
    else: sys.exit(92)
'''


class RepairTests(unittest.TestCase):
    def run_case(self, *, apply=False, full_backup=False, **overrides):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            executable = root / 'podman'
            executable.write_text(PODMAN)
            executable.chmod(0o755)
            fixture = root / 'fixture.json'
            fixture.write_text(json.dumps(dict(table=TABLE, index=INDEX, definition=DEFINITION, **overrides)))
            backup = root / 'backup'
            backup.mkdir()
            if full_backup:
                for name in ('html.tgz', 'data.tgz', 'config.tgz', 'nextcloud.pgdump', 'roles.sql'):
                    (backup / name).write_text('test archive placeholder')
                import hashlib
                (backup / 'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n'
                    for p in sorted(backup.iterdir())))
            command = [sys.executable, '-O', str(ROOT / 'scripts/repair-nextcloud-sharing-index.py'), '--backup', str(backup)]
            if apply:
                command.append('--apply')
            result = subprocess.run(command, env=dict(os.environ, PATH=str(root)+os.pathsep+os.environ['PATH'], FIXTURE=str(fixture)),
                                    text=True, capture_output=True)
            state = json.loads(fixture.read_text())
            ddl = root / 'sharing-legacy-index-rollback.sql'
            return result, state, ddl.read_text() if ddl.exists() else None

    def test_preview_never_mutates(self):
        result, state, ddl = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)['preview'])
        self.assertNotIn('applied', state)
        self.assertIsNone(ddl)

    def test_apply_requires_backup_and_preserves_rollback(self):
        result, state, ddl = self.run_case(apply=True, full_backup=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(state['applied'])
        self.assertEqual(ddl, DEFINITION+';\n')
        self.assertEqual(json.loads(result.stdout)['schema_findings'], [])

    def test_missing_backup_refused(self):
        result, state, _ = self.run_case(apply=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('applied', state)

    def test_nonempty_table_refused_even_under_python_optimization(self):
        result, state, _ = self.run_case(apply=True, full_backup=True, rows=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('applied', state)

    def test_other_version_refused_even_under_python_optimization(self):
        result, state, _ = self.run_case(apply=True, full_backup=True, version='35.0.4')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('applied', state)


if __name__ == '__main__':
    unittest.main()

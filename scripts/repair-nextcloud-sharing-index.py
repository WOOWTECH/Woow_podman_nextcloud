#!/usr/bin/env python3
"""Review-gated cleanup of one empty legacy sharing table on Nextcloud 35.0.3.

Not a general schema repair tool. A full database/application backup is required.
Official source: nextcloud/server@52a07c0b16ec1dd622003af9c4cbbb3429c64e08.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

os.umask(0o077)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--app', default='nextcloud-app')
p.add_argument('--db', default='nextcloud-db')
p.add_argument('--backup', type=Path, required=True)
p.add_argument('--apply', action='store_true')
a = p.parse_args()
table = 'oc_sharing_share_recipients'
index = 'uniq_734621b62ae63fdb4185a14495a838f'

def run(args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()

def occ(*args):
    return run(['podman', 'exec', '-u', 'www-data', a.app, 'php', 'occ', *args])

def sql(query):
    return run(['podman', 'exec', a.db, 'psql', '-Unextcloud', '-dnextcloud', '-vON_ERROR_STOP=1', '-Atqc', query])

if not (json.loads(occ('status', '--output=json'))['versionstring'] == '35.0.3'):
    raise RuntimeError('Reviewed schema precondition failed')
if not (occ('config:app:get', 'sharing', 'installed_version') == '1.0.5'):
    raise RuntimeError('Reviewed schema precondition failed')
expected = json.loads(occ('db:schema:expected', table, '--output=json'))[table]['indexes']
if not (index not in expected):
    raise RuntimeError('Reviewed schema precondition failed')
if not (expected[table + '_pkey']['columns'] == ['id']):
    raise RuntimeError('Reviewed schema precondition failed')
if not (expected['uniq_734621b645af3a']['columns'] == ['recipient_secret']):
    raise RuntimeError('Reviewed schema precondition failed')
if not (expected['uniq_734621b645af3a']['unique']):
    raise RuntimeError('Reviewed schema precondition failed')
if not (sql('SELECT count(*) FROM ' + table) == '0'):
    raise RuntimeError('Nonempty table requires separate review')
check = subprocess.run(['podman', 'exec', '-u', 'www-data', a.app, 'php', 'occ', 'db:schema:check', '--output=json'], capture_output=True, text=True)
if check.returncode not in (0, 1):
    raise RuntimeError("Schema check command failed")
findings = json.loads(check.stdout)
if not findings:
    print(json.dumps({'passed': True, 'already_clean': True}))
    raise SystemExit(0)
if not (len(findings) == 1 and findings[0]['table'] == table and findings[0]['name'] == index and findings[0]['type'] == 'unexpected_index'):
    raise RuntimeError(findings)
definition = sql("SELECT indexdef FROM pg_indexes WHERE schemaname='public' AND tablename='" + table + "' AND indexname='" + index + "'")
if not (definition == 'CREATE UNIQUE INDEX ' + index + ' ON public.' + table + ' USING btree (share_id, recipient_class_id, recipient_value)'):
    raise RuntimeError('Reviewed schema precondition failed')
if not (sql("SELECT count(*) FROM pg_constraint WHERE conindid='" + index + "'::regclass") == '0'):
    raise RuntimeError('Reviewed schema precondition failed')
other = sql("SELECT indexname || ':' || indexdef FROM pg_indexes WHERE tablename='" + table + "' AND indexname <> '" + index + "' ORDER BY indexname")
if not (all(name in other for name in expected)):
    raise RuntimeError('Reviewed schema precondition failed')
constraints = sql("SELECT oid::text || ':' || pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='" + table + "'::regclass OR confrelid='" + table + "'::regclass ORDER BY oid")
if not a.apply:
    print(json.dumps({'preview': True, 'empty_table': True, 'drop_index': index, 'other_constraints_preserved': True}))
    raise SystemExit(0)
if not (all((a.backup / name).is_file() for name in ('html.tgz', 'data.tgz', 'config.tgz', 'nextcloud.pgdump', 'roles.sql', 'SHA256SUMS'))):
    raise RuntimeError('Reviewed schema precondition failed')
subprocess.run(['sha256sum', '-c', '--quiet', 'SHA256SUMS'], cwd=a.backup, check=True)
saved = a.backup.parent / 'sharing-legacy-index-rollback.sql'
with saved.open('x') as output:
    output.write(definition + ';\n')
# The row/constraint checks also run inside the lock: concurrent inserts cannot
# turn an empty-table-only repair into a change to a populated table.
statement = """BEGIN;
SET LOCAL lock_timeout = '10s';
LOCK TABLE oc_sharing_share_recipients IN ACCESS EXCLUSIVE MODE;
DO $$ BEGIN
 IF pg_get_indexdef('public.uniq_734621b62ae63fdb4185a14495a838f'::regclass) <> 'CREATE UNIQUE INDEX uniq_734621b62ae63fdb4185a14495a838f ON public.oc_sharing_share_recipients USING btree (share_id, recipient_class_id, recipient_value)' THEN
  RAISE EXCEPTION 'Index changed; repair refused';
 END IF;
 IF EXISTS (SELECT 1 FROM oc_sharing_share_recipients) THEN
  RAISE EXCEPTION 'Sharing table changed; repair refused';
 END IF;
 IF EXISTS (SELECT 1 FROM pg_constraint WHERE conindid='uniq_734621b62ae63fdb4185a14495a838f'::regclass) THEN
  RAISE EXCEPTION 'Index is constraint-owned; repair refused';
 END IF;
END $$;
DROP INDEX public.uniq_734621b62ae63fdb4185a14495a838f;
COMMIT;"""
sql(statement)
try:
    if not (sql("SELECT indexname || ':' || indexdef FROM pg_indexes WHERE tablename='" + table + "' ORDER BY indexname") == other):
        raise RuntimeError('Reviewed schema precondition failed')
    if not (sql("SELECT oid::text || ':' || pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='" + table + "'::regclass OR confrelid='" + table + "'::regclass ORDER BY oid") == constraints):
        raise RuntimeError('Reviewed schema precondition failed')
    if not (json.loads(occ('db:schema:check', '--output=json')) == []):
        raise RuntimeError('Reviewed schema precondition failed')
except BaseException:
    sql(definition)
    raise
print(json.dumps({'passed': True, 'schema_findings': [], 'empty_legacy_table': True, 'only_obsolete_index_removed': index, 'other_indexes_primary_and_foreign_keys_preserved': True, 'rollback_ddl_sha256': hashlib.sha256(saved.read_bytes()).hexdigest()}))

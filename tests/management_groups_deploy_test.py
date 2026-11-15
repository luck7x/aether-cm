#!/usr/bin/env python3
"""Exercise deployment compensation with isolated fake services and PostgreSQL."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
p = pathlib.Path(os.environ['FIXTURE_STATE'])
s = json.loads(p.read_text())
current = pathlib.Path(os.environ['INSTALL_ROOT']) / 'current'
new = current.resolve().name != 'old'
def save(): p.write_text(json.dumps(s))
def finish(value='', rc=0):
 if value: print(value)
 sys.exit(rc)
if name == 'id': finish('0')
if name == 'stat': finish('0:600')
if name in ('sleep', 'chown'): finish()
if name == 'df': finish('Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 999999999 1 999999998 1% /')
if name == 'runuser': os.execvp(args[3], args[3:])
if name == 'pg_dump':
 if s['failure'] == 'backup': finish(rc=1)
 finish('fixture-database-backup')
if name == 'pg_restore': finish('fixture-database-backup-index')
if name == 'mv':
 src = next((a for a in args if not a.startswith('-')), '')
 if (s['failure'] == 'link' and '/.update-' in src) or (s['failure'] == 'manual-link' and '/.rollback-' in src): finish(rc=1)
 os.execv('/bin/mv', ['/bin/mv'] + args)
if name == 'systemctl':
 if args[0] == 'stop': s['active'] = False; s['stops'] += 1; save(); finish()
 if args[0] == 'start':
  if s['failure'] == 'start' and new: finish(rc=1)
  s['active'] = True; save(); finish()
 if args[0] == 'show': finish('12345')
 if args[0] == 'is-active': finish('' if '--quiet' in args else ('active' if s['active'] else 'inactive'), 0 if s['active'] else 3)
if name == 'curl':
 if 'provider-management-groups' in args[-1]: finish('401')
 finish(rc=0 if s['active'] and not (new and s['failure'] == 'health') else 22)
if name == 'aether-gateway':
 if args == ['db', 'status']:
  finish('pending migrations: '+('2' if s['failure']=='extra-migration' else '1')+'\nnext migration: 20261115000000 (provider management groups)')
 if args == ['--migrate']:
  s['migrated'] = True; save(); finish(rc=1 if s['failure']=='migrate-after-commit' else 0)
 finish()
if name == 'psql':
 q = args[-1] if args and not args[-1].startswith('-') else ''
 if 'SELECT' not in q and 'DELETE' not in q:
  q = sys.stdin.read()
 if 'json_populate_record' in q: s['migrated']=True; save(); finish('INSERT 0 1')
 if 'DELETE FROM' in q:
  removed = int(s['migrated']); s['migrated']=False; save(); finish(str(removed) if 'WITH removed' in q else 'DELETE '+str(removed))
 if 'pg_postmaster_start_time' in q: finish('same-start|5432|123')
 if "current_setting('port')" in q: finish('5432')
 if 'current_database()' in q and 'pg_database_size' not in q: finish('fixture')
 if 'pg_database_size' in q: finish('1024')
 if 'max(version)' in q: finish('20261115000000' if s['migrated'] else '20261009000000')
 if 'NOT success' in q: finish('0')
 if 'count(*)' in q: finish('1' if s['migrated'] else '0')
 if 'row_to_json' in q: finish(json.dumps({'version':20261115000000,'checksum':'\\xaaaa','success':True}))
 if "SELECT encode(checksum" in q: finish('a' * 96)
 if "SELECT version, encode" in q: finish('20261009000000|bbbb|t'+ ('\n20261115000000|' + 'a' * 96 + '|t' if s['migrated'] else ''))
 if 'SELECT version' in q: finish('20261009000000'+ ('\n20261115000000' if s['migrated'] else ''))
 finish('unhandled fixture SQL', 1)
finish('unhandled fixture command '+name, 1)
'''


class DeploymentFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.private = self.base / 'private'
        self.private.mkdir()
        self.fakebin = self.base / 'fakebin'
        self.fakebin.mkdir()
        self.install = self.base / 'aether'
        (self.install / 'releases' / 'old' / 'bin').mkdir(parents=True)
        old = self.install / 'releases' / 'old'
        (old / 'bin' / 'aether-gateway').write_text('old')
        (old / 'bin' / 'aether-gateway').chmod(0o755)
        (self.install / 'current').symlink_to(old)
        self.state = self.base / 'state.json'
        self.state.write_text(json.dumps({'failure': '', 'migrated': False, 'active': True, 'stops': 0}))
        for name in ['psql', 'pg_dump', 'pg_restore', 'systemctl', 'curl', 'runuser', 'id', 'stat', 'chown', 'df', 'sleep', 'mv']:
            path = self.fakebin / name
            path.write_text(FAKE)
            path.chmod(0o755)
        self.scripts = self.base / 'scripts'
        self.scripts.mkdir()
        for name in ['install-management-groups-update.sh', 'rollback-management-groups-update.sh', 'prepare-deploy-postgres.py']:
            text = (ROOT / '.cm' / name).read_text()
            text = text.replace('/root/', str(self.private) + '/').replace('/run/lock/', str(self.base) + '/')
            text = text.replace('export PATH="', f'export PATH="{self.fakebin}:', 1)
            (self.scripts / name).write_text(text)
        self.bundle = self.base / 'bundle'
        (self.bundle / 'bin').mkdir(parents=True)
        (self.bundle / 'frontend').mkdir()
        (self.bundle / 'frontend' / 'index.html').write_text('<html>fixture</html>')
        (self.bundle / 'bin' / 'aether-gateway').write_text(FAKE)
        (self.bundle / 'bin' / 'aether-gateway').chmod(0o755)
        sha = 'a' * 40
        (self.bundle / 'BUILD_INFO').write_text('git_sha=' + sha + '\n')
        envfile = self.base / 'app.env'
        envfile.write_text('DATABASE_URL="postgresql://fixture:placeholder@127.0.0.1/fixture"\nAPP_PORT=63665\n')
        digest = subprocess.check_output(['bash', '-c', 'find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum'], cwd=self.bundle / 'frontend', text=True).split()[0]
        self.env = dict(os.environ, FIXTURE_STATE=str(self.state), INSTALL_ROOT=str(self.install),
                        AETHER_ENV_FILE=str(envfile), AETHER_BUNDLE_ROOT=str(self.bundle), AETHER_EXPECTED_BUILD_SHA=sha,
                        AETHER_EXPECTED_GATEWAY_SHA256=hashlib.sha256(FAKE.encode()).hexdigest(),
                        AETHER_EXPECTED_FRONTEND_SHA256=digest, AETHER_EXPECTED_MIGRATION_CHECKSUM='a' * 96, PYTHONDONTWRITEBYTECODE='1')
        for key in ['AETHER_DATABASE_URL', 'AETHER_GATEWAY_DATA_POSTGRES_URL', 'PGSERVICEFILE', 'PGSERVICE']:
            self.env.pop(key, None)

    def tearDown(self):
        self.tmp.cleanup()

    def failure(self, mode):
        state = json.loads(self.state.read_text()); state['failure'] = mode
        self.state.write_text(json.dumps(state))

    def run_script(self, name):
        return subprocess.run(['bash', str(self.scripts / name)], env=self.env, text=True, capture_output=True, timeout=30)

    def assert_old_healthy(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.install / 'current').resolve().name, 'old')
        state = json.loads(self.state.read_text())
        self.assertTrue(state['active'], result.stdout + result.stderr)
        self.assertFalse(state['migrated'])
        self.assertFalse(list(self.private.rglob('postgres.service.conf')))

    def test_install_and_manual_rollback(self):
        result = self.run_script('install-management-groups-update.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(json.loads(self.state.read_text())['migrated'])
        result = self.run_script('rollback-management-groups-update.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.install / 'current').resolve().name, 'old')
        self.assertFalse(json.loads(self.state.read_text())['migrated'])

    def test_failure_compensation(self):
        for index, mode in enumerate(['backup', 'extra-migration', 'migrate-after-commit', 'link', 'start', 'health']):
            if index:
                self.tearDown()
                self.setUp()
            with self.subTest(mode=mode):
                self.failure(mode)
                result = self.run_script('install-management-groups-update.sh')
                self.assert_old_healthy(result)
                stops = json.loads(self.state.read_text())['stops']
                self.assertEqual(stops == 0, mode in ('backup', 'extra-migration'), result.stdout + result.stderr)

    def test_manual_rollback_failure_recovers_new_release(self):
        result = self.run_script('install-management-groups-update.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        target = (self.install / 'current').resolve()
        self.failure('manual-link')
        result = self.run_script('rollback-management-groups-update.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.install / 'current').resolve(), target)
        state = json.loads(self.state.read_text())
        self.assertTrue(state['active'], result.stdout + result.stderr)
        self.assertTrue(state['migrated'], result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Write a private libpq service file without putting credentials in argv."""
import os
from pathlib import Path
import sys
from urllib.parse import parse_qsl, unquote, urlsplit

url = urlsplit(os.environ['AETHER_DEPLOY_DATABASE_CONNECTION'])
if url.scheme not in ('postgres', 'postgresql'):
    raise SystemExit('PostgreSQL URL required')
fields = dict(parse_qsl(url.query, keep_blank_values=True))
fields.setdefault('host', url.hostname or '/var/run/postgresql')
fields.setdefault('port', str(url.port or 5432))
fields.setdefault('dbname', unquote(url.path.lstrip('/')))
if url.username is not None:
    fields.setdefault('user', unquote(url.username))
if url.password is not None:
    fields.setdefault('password', unquote(url.password))
# The peer-admin backup path is only supported for this local production cluster.
if fields['host'] not in ('localhost', '127.0.0.1', '::1', '/var/run/postgresql'):
    raise SystemExit('This installer supports local PostgreSQL only')
if any('\n' in value or '\r' in value or '\0' in value for value in fields.values()):
    raise SystemExit('Invalid PostgreSQL service value')
if any(not key.replace('_', '').isalnum() for key in fields):
    raise SystemExit('Invalid PostgreSQL service key')
path = Path(sys.argv[1])
with open(path, 'w', opener=lambda name, flags: os.open(name, flags, 0o600)) as target:
    target.write('[aether_management_update]\n')
    target.writelines(f'{key}={value}\n' for key, value in fields.items())
os.chmod(path, 0o600)

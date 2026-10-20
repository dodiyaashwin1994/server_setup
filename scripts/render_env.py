#!/usr/bin/env python3
"""Writes infra/.env: the passwords of MySQL, Redis and RabbitMQ (read by docker compose). Used by the full setup only; adding hosts never touches it."""
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / 'infra'
_SECRETS = json.loads(os.environ.get('ALL_SECRETS') or '{}')


def get(name, default=''):
    return os.environ.get(name) or _SECRETS.get(name) or default


def main():
    names = ('MYSQL_ROOT_PASSWORD', 'REDIS_PASSWORD', 'RABBITMQ_USERNAME', 'RABBITMQ_PASSWORD', 'RABBITMQ_ERLANG_COOKIE')
    missing = [n for n in names if not get(n)]
    if missing:
        sys.exit('Missing secrets: ' + ', '.join(missing) + '. Load them with leezify_env/scripts/push-secrets.sh.')
    pairs = [('MYSQL_ROOT_PASSWORD', get('MYSQL_ROOT_PASSWORD')), ('MYSQL_PORT', get('MYSQL_PORT', '3306')), ('REDIS_PASSWORD', get('REDIS_PASSWORD')), ('REDIS_PORT', get('REDIS_PORT', '6379')),
             ('REDIS_MAXMEMORY', get('REDIS_MAXMEMORY', '512mb')), ('REDIS_MAXMEMORY_POLICY', get('REDIS_MAXMEMORY_POLICY', 'allkeys-lru')),
             ('RABBITMQ_USERNAME', get('RABBITMQ_USERNAME')), ('RABBITMQ_PASSWORD', get('RABBITMQ_PASSWORD')), ('RABBITMQ_ERLANG_COOKIE', get('RABBITMQ_ERLANG_COOKIE'))]
    (ROOT / '.env').write_text('\n'.join(f"{k}={str(v).replace('$', '$$')}" for k, v in pairs) + '\n')
    (ROOT / '.env').chmod(0o600)
    print('wrote infra/.env')


if __name__ == '__main__':
    main()

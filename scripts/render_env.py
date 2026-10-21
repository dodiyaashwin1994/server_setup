#!/usr/bin/env python3
"""Writes infra/.env (read by docker compose) from the values the Setup infrastructure workflow was given: the passwords of MySQL, Redis and RabbitMQ and the bind addresses of their ports."""
import ipaddress
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / 'infra'
REQUIRED = ('MYSQL_ROOT_PASSWORD', 'REDIS_PASSWORD', 'RABBITMQ_USERNAME', 'RABBITMQ_PASSWORD')
BINDS = ('MYSQL_BIND_ADDRESS', 'REDIS_BIND_ADDRESS', 'RABBITMQ_BIND_ADDRESS')


def get(name, default=''):
    return (os.environ.get(name) or default).strip()


def main():
    missing = [n for n in REQUIRED if not os.environ.get(n)]
    if missing:
        sys.exit('Missing: ' + ', '.join(missing) + '. Give them as inputs of the workflow, or load them as secrets of the environment.')
    pairs = [(n, os.environ[n]) for n in REQUIRED]
    for n in BINDS:
        value = get(n, '127.0.0.1')
        try:
            ipaddress.ip_address(value)
        except ValueError:
            sys.exit(f'{n} must be an IP address (127.0.0.1 = this machine only, 0.0.0.0 = every address), not "{value}"')
        pairs.append((n, value))
    pairs += [('MYSQL_PORT', get('MYSQL_PORT', '3306')), ('REDIS_PORT', get('REDIS_PORT', '6379')),
              ('REDIS_MAXMEMORY', get('REDIS_MAXMEMORY', '512mb')), ('REDIS_MAXMEMORY_POLICY', get('REDIS_MAXMEMORY_POLICY', 'allkeys-lru'))]
    for k, v in pairs:
        if "'" in v or '\n' in v or '\r' in v:
            sys.exit(f'{k} must not contain a single quote or a line break')
    # single quotes: docker compose then takes the value literally ($, #, spaces and all)
    (ROOT / '.env').write_text('\n'.join(f"{k}='{v}'" for k, v in pairs) + '\n')
    (ROOT / '.env').chmod(0o600)
    print('wrote infra/.env')


if __name__ == '__main__':
    main()

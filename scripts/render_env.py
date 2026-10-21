#!/usr/bin/env python3
"""Writes infra/.env (read by docker compose, by nginx-route and by mysql/ensure-user.sh) from the values the Setup infrastructure workflow was given.

A value typed in the workflow wins; a value left empty keeps the one in the .env already on the server (the workflow fetches it to infra/.env.server first), so a run that redeploys
one service does not need every password again. Only what is neither typed nor on the server is an error.

MySQL's port: closed (127.0.0.1) unless MYSQL_REMOTE_IPS lists the addresses that may connect. The list is applied whenever MySQL is deployed (DEPLOY_MYSQL=true), and an empty list closes it.
Redis and RabbitMQ stay on 127.0.0.1.
"""
import ipaddress
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / 'infra'


def parse(path):
    out = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if '=' in line and not line.startswith('#'):
                k, v = line.split('=', 1)
                out[k] = v[1:-1] if len(v) >= 2 and v[0] == v[-1] == "'" else v
    return out


existing = parse(ROOT / '.env.server')


def pick(name, default=''):
    return os.environ.get(name) or existing.get(name) or default


def flag(name):
    return os.environ.get(name, '').strip().lower() == 'true'


def need(name, label):
    value = pick(name)
    if not value:
        sys.exit(f'{label} is empty: type it as an input of the run (the server has no value for it yet).')
    return value


def networks(text):
    """The IPv4 addresses / networks of MYSQL_REMOTE_IPS, normalised. Never everyone, never IPv6."""
    found = []
    for item in [t for t in re.split(r'[\s,;]+', text.strip()) if t]:
        try:
            net = ipaddress.ip_network(item, strict=False)
        except ValueError:
            sys.exit(f'mysql_remote_ips: "{item}" is not an IP address or network (e.g. 203.0.113.7 or 203.0.113.0/24)')
        if net.version != 4:
            sys.exit(f'mysql_remote_ips: "{item}" is IPv6; only IPv4 addresses are supported')
        if net.prefixlen < 16:
            sys.exit(f'mysql_remote_ips: "{item}" is too wide (at most a /16): the point is to allow only your own address')
        found.append(str(net.network_address) if net.prefixlen == 32 else str(net))
    return found


def main():
    user = pick('MYSQL_USERNAME', 'root')
    if not re.fullmatch(r'[A-Za-z0-9_]{1,32}', user):
        sys.exit('MYSQL_USERNAME must be letters, digits and _ (at most 32)')
    mysql_pw = need('MYSQL_PASSWORD', 'The MySQL password')
    redis_pw = need('REDIS_PASSWORD', 'The Redis password')
    rabbit_user = pick('RABBITMQ_USERNAME', 'root')
    rabbit_pw = need('RABBITMQ_PASSWORD', 'The RabbitMQ password')
    email = pick('ACME_EMAIL')
    if not re.fullmatch(r'[^@\s]+@[^@\s]+\.[A-Za-z]{2,}', email):
        sys.exit("ACME_EMAIL must be an e-mail address (Let's Encrypt writes to it before a certificate expires)")

    # MySQL's remote access: applied when MySQL is (re)deployed; an empty list closes it
    deploy_mysql = flag('DEPLOY_MYSQL')
    ips = networks(os.environ.get('MYSQL_REMOTE_IPS', '') if deploy_mysql else existing.get('MYSQL_REMOTE_IPS', ''))
    remote_user = pick('MYSQL_REMOTE_USER', 'dba')
    if not re.fullmatch(r'[A-Za-z0-9_]{1,32}', remote_user) or remote_user in ('root', user):
        sys.exit('mysql_remote_user must be letters, digits and _ (at most 32), and different from root and the service user')
    remote_pw = pick('MYSQL_REMOTE_PASSWORD')
    if ips and len(remote_pw) < 12:
        sys.exit('mysql_remote_password is required (at least 12 characters) when mysql_remote_ips is set: that login is reachable from the internet')
    bind = ('0.0.0.0' if ips else '127.0.0.1') if deploy_mysql else existing.get('MYSQL_BIND_ADDRESS', '127.0.0.1')

    pairs = [('MYSQL_USERNAME', user), ('MYSQL_PASSWORD', mysql_pw), ('MYSQL_ROOT_PASSWORD', mysql_pw),
             ('MYSQL_REMOTE_IPS', ','.join(ips)), ('MYSQL_REMOTE_USER', remote_user), ('MYSQL_REMOTE_PASSWORD', remote_pw),
             ('REDIS_PASSWORD', redis_pw), ('RABBITMQ_USERNAME', rabbit_user), ('RABBITMQ_PASSWORD', rabbit_pw),
             ('ACME_EMAIL', email), ('ACME_STAGING', 'true' if flag('ACME_STAGING') else 'false'),
             ('MYSQL_BIND_ADDRESS', bind), ('REDIS_BIND_ADDRESS', '127.0.0.1'), ('RABBITMQ_BIND_ADDRESS', '127.0.0.1'),
             ('MYSQL_PORT', pick('MYSQL_PORT', '3306')), ('REDIS_PORT', pick('REDIS_PORT', '6379')),
             ('REDIS_MAXMEMORY', pick('REDIS_MAXMEMORY', '512mb')), ('REDIS_MAXMEMORY_POLICY', pick('REDIS_MAXMEMORY_POLICY', 'allkeys-lru'))]
    for k, v in pairs:
        if "'" in v or '\n' in v or '\r' in v:
            sys.exit(f'{k} must not contain a single quote or a line break')
        if k in ('MYSQL_PASSWORD', 'MYSQL_REMOTE_PASSWORD') and '\\' in v:
            sys.exit(f'{k} must not contain a backslash')
    # single quotes: docker compose then takes the value literally ($, #, spaces and all)
    (ROOT / '.env').write_text('\n'.join(f"{k}='{v}'" for k, v in pairs) + '\n')
    (ROOT / '.env').chmod(0o600)
    print('wrote infra/.env; MySQL port: ' + (f'open to {", ".join(ips)} (login {remote_user})' if ips else 'closed (127.0.0.1)') + ('' if deploy_mysql else ' [as already configured: MySQL is not being redeployed]'))


if __name__ == '__main__':
    main()

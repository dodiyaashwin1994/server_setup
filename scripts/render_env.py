#!/usr/bin/env python3
"""Writes infra/.env (read by docker compose, by nginx-route and by mysql/ensure-user.sh) from the values the Setup infrastructure workflow was given.

A value typed in the workflow wins; a value left empty keeps the one in the .env already on the server (the workflow fetches it to infra/.env.server first), so a run that redeploys
one service does not need every password again. Only what is neither typed nor on the server is an error.

MySQL's port (MYSQL_PORT, 4567 by default, published for tools outside the server): closed (127.0.0.1) unless MYSQL_REMOTE_IPS lists the addresses that may connect, or says `any` (everyone). The list is applied when MySQL
is deployed (DEPLOY_MYSQL=true; an empty list closes the port) or when only its accounts are updated (UPDATE_MYSQL_ACCESS=true, no restart; opening or closing the port itself needs a deploy).
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
    """The IPv4 addresses / networks of MYSQL_REMOTE_IPS, normalised; or ['any'] for the keyword `any` (open to everyone, on purpose). Never IPv6."""
    found = []
    items = [t for t in re.split(r'[\s,;]+', text.strip()) if t]
    if any(t.lower() in ('any', '*') for t in items):
        if len(items) > 1:
            sys.exit('mysql_remote_ips: "any" means everyone and cannot be combined with addresses')
        return ['any']
    for item in items:
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

    # MySQL's remote access: the listed addresses may log in as root / the service user; the port opens only when MySQL is deployed with a list
    deploy_mysql, update_access = flag('DEPLOY_MYSQL'), flag('UPDATE_MYSQL_ACCESS')
    ips = networks(os.environ.get('MYSQL_REMOTE_IPS', '') if (deploy_mysql or update_access) else existing.get('MYSQL_REMOTE_IPS', ''))
    port = pick('MYSQL_PORT', '4567')
    if not port.isdigit() or not 1024 <= int(port) <= 65535 or int(port) in (3306, 6379, 5672, 15672, 80, 443, 22):
        sys.exit('mysql_port must be a number between 1024 and 65535, not one of the usual service ports (e.g. 4567)')
    bind = ('0.0.0.0' if ips else '127.0.0.1') if deploy_mysql else existing.get('MYSQL_BIND_ADDRESS', '127.0.0.1')
    if ips and not deploy_mysql and bind != '0.0.0.0':
        print("WARNING: the MySQL port is still closed: tick deploy_mysql as well to open it (the accounts are updated either way)", file=sys.stderr)

    pairs = [('MYSQL_USERNAME', user), ('MYSQL_PASSWORD', mysql_pw), ('MYSQL_ROOT_PASSWORD', mysql_pw),
             ('MYSQL_REMOTE_IPS', ','.join(ips)),
             ('REDIS_PASSWORD', redis_pw), ('RABBITMQ_USERNAME', rabbit_user), ('RABBITMQ_PASSWORD', rabbit_pw),
             ('ACME_EMAIL', email), ('ACME_STAGING', 'true' if flag('ACME_STAGING') else 'false'),
             ('MYSQL_BIND_ADDRESS', bind), ('REDIS_BIND_ADDRESS', '127.0.0.1'), ('RABBITMQ_BIND_ADDRESS', '127.0.0.1'),
             ('MYSQL_PORT', port), ('REDIS_PORT', pick('REDIS_PORT', '6379')),
             ('REDIS_MAXMEMORY', pick('REDIS_MAXMEMORY', '512mb')), ('REDIS_MAXMEMORY_POLICY', pick('REDIS_MAXMEMORY_POLICY', 'allkeys-lru'))]
    for k, v in pairs:
        if "'" in v or '\n' in v or '\r' in v:
            sys.exit(f'{k} must not contain a single quote or a line break')
        if k == 'MYSQL_PASSWORD' and '\\' in v:
            sys.exit(f'{k} must not contain a backslash')
    # single quotes: docker compose then takes the value literally ($, #, spaces and all)
    (ROOT / '.env').write_text('\n'.join(f"{k}='{v}'" for k, v in pairs) + '\n')
    (ROOT / '.env').chmod(0o600)
    print(f'wrote infra/.env; MySQL port {port}: ' + (('OPEN TO EVERYONE (only the password protects it)' if ips == ['any'] else f'for {", ".join(ips)} only') if ips else 'closed (127.0.0.1)') + ('' if deploy_mysql or update_access else ' [as already configured: MySQL is not being redeployed]'))


if __name__ == '__main__':
    main()

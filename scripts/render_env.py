#!/usr/bin/env python3
"""Writes, from the secrets of the GitHub environment:
    infra/.env                        passwords of MySQL, Redis and RabbitMQ (read by docker compose)
    infra/nginx/conf.d/leezify.conf   the edge: which host name goes to which app
    infra/certs/fullchain.pem         the certificate from Hostinger (certificate + intermediates)
    infra/certs/privkey.pem           its private key
The certificate and key are secrets in base64 (one line): TLS_CERT_PEM_BASE64 and TLS_KEY_PEM_BASE64 (leezify_env/scripts/set-tls.sh sets them).
"""
import base64
import binascii
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / 'infra'
_SECRETS = json.loads(os.environ.get('ALL_SECRETS') or '{}')


def get(name, default=''):
    return os.environ.get(name) or _SECRETS.get(name) or default


def need(*names):
    missing = [n for n in names if not get(n)]
    if missing:
        sys.exit('Missing secrets: ' + ', '.join(missing) + '. Load them with leezify_env/scripts/push-secrets.sh (the certificate with set-tls.sh).')


def esc(v):
    return str(v).replace('$', '$$')


def pem(name):
    try:
        text = base64.b64decode(get(name), validate=True).decode()
    except (binascii.Error, UnicodeDecodeError):
        sys.exit(f'{name} is not valid base64')
    if '-----BEGIN' not in text:
        sys.exit(f'{name} does not hold a PEM file')
    return text.strip() + '\n'


def main():
    need('MYSQL_ROOT_PASSWORD', 'REDIS_PASSWORD', 'RABBITMQ_USERNAME', 'RABBITMQ_PASSWORD', 'RABBITMQ_ERLANG_COOKIE', 'SERVICE_DOMAIN', 'TLS_CERT_PEM_BASE64', 'TLS_KEY_PEM_BASE64')
    pairs = [('MYSQL_ROOT_PASSWORD', get('MYSQL_ROOT_PASSWORD')), ('MYSQL_PORT', get('MYSQL_PORT', '3306')), ('REDIS_PASSWORD', get('REDIS_PASSWORD')), ('REDIS_PORT', get('REDIS_PORT', '6379')),
             ('REDIS_MAXMEMORY', get('REDIS_MAXMEMORY', '512mb')), ('REDIS_MAXMEMORY_POLICY', get('REDIS_MAXMEMORY_POLICY', 'allkeys-lru')),
             ('RABBITMQ_USERNAME', get('RABBITMQ_USERNAME')), ('RABBITMQ_PASSWORD', get('RABBITMQ_PASSWORD')), ('RABBITMQ_ERLANG_COOKIE', get('RABBITMQ_ERLANG_COOKIE'))]
    (ROOT / '.env').write_text('\n'.join(f'{k}={esc(v)}' for k, v in pairs) + '\n')
    (ROOT / '.env').chmod(0o600)
    domain, suffix = get('SERVICE_DOMAIN').strip().lower(), get('ENV_SUFFIX')
    if not re.match(r'^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$', domain):
        sys.exit(f'SERVICE_DOMAIN is not a domain: {domain}')
    conf = (ROOT / 'nginx/leezify.conf.template').read_text().replace('__DOMAIN_RE__', re.escape(domain)).replace('__DOMAIN__', domain).replace('__SUFFIX__', suffix)
    (ROOT / 'nginx/conf.d').mkdir(parents=True, exist_ok=True)
    (ROOT / 'nginx/conf.d/leezify.conf').write_text(conf)
    (ROOT / 'certs').mkdir(exist_ok=True)
    (ROOT / 'certs/fullchain.pem').write_text(pem('TLS_CERT_PEM_BASE64'))
    (ROOT / 'certs/privkey.pem').write_text(pem('TLS_KEY_PEM_BASE64'))
    (ROOT / 'certs/privkey.pem').chmod(0o600)
    print(f'wrote the edge for {domain} (apps ui-user{suffix}, ui-admin{suffix}), the certificate and the passwords')


if __name__ == '__main__':
    main()

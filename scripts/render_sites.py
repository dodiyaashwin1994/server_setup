#!/usr/bin/env python3
"""Turns the list of routes into nginx site files (and the certificates that go with them).

    ROUTES      host=container:port, separated by commas, spaces or new lines.   app.example.com=ui-user:80, api.example.com=api:8000
    REMOVE      host names to delete, same separators.
Both come from the workflow inputs (ROUTES_INPUT, REMOVE_INPUT); when the routes input is empty the ROUTES secret of the environment is used.

Writes:
    infra/nginx/sites/<host>.conf         one file per host (nothing else on the server is touched)
    infra/certs/<base>/{fullchain,privkey}.pem   only for a domain whose certificate is in the secrets; <base> is the host without its first label (app.example.com -> example.com)
    .render/bases.txt                     every domain the routes need a certificate for
    .render/remove.txt                    hosts to delete on the server

Certificate secrets: for the main domain (SERVICE_DOMAIN) TLS_CERT_PEM_BASE64 / TLS_KEY_PEM_BASE64; for another domain TLS_<DOMAIN>_CERT_PEM_BASE64 / TLS_<DOMAIN>_KEY_PEM_BASE64
with the dots and dashes of the domain written as underscores, in capitals (shop.net -> TLS_SHOP_NET_CERT_PEM_BASE64). A certificate that is already on the server is reused.
"""
import base64
import binascii
import json
import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INFRA = REPO / 'infra'
OUT = REPO / '.render'
_SECRETS = json.loads(os.environ.get('ALL_SECRETS') or '{}')
HOST = re.compile(r'^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$')
UPSTREAM = re.compile(r'^[a-z0-9][a-z0-9_.-]*:[0-9]{1,5}$')


def get(name, default=''):
    return os.environ.get(name) or _SECRETS.get(name) or default


def words(text):
    return [w for w in re.split(r'[\s,;]+', text.strip()) if w]


def base_of(host):
    labels = host.split('.')
    return host if len(labels) <= 2 else '.'.join(labels[1:])


def secret_names(base):
    if base == get('SERVICE_DOMAIN').strip().lower():
        return 'TLS_CERT_PEM_BASE64', 'TLS_KEY_PEM_BASE64'
    tag = re.sub(r'[^A-Z0-9]', '_', base.upper())
    return f'TLS_{tag}_CERT_PEM_BASE64', f'TLS_{tag}_KEY_PEM_BASE64'


def pem(name):
    try:
        text = base64.b64decode(get(name), validate=True).decode()
    except (binascii.Error, UnicodeDecodeError):
        sys.exit(f'{name} is not valid base64')
    if '-----BEGIN' not in text:
        sys.exit(f'{name} does not hold a PEM file')
    return text.strip() + '\n'


def main():
    routes = {}
    for item in words(os.environ.get('ROUTES_INPUT', '') or get('ROUTES')):
        host, _, upstream = item.partition('=')
        host = host.lower()
        if not HOST.match(host):
            sys.exit(f'"{host}" is not a host name (expected something like app.example.com)')
        if not UPSTREAM.match(upstream) or not 0 < int(upstream.rsplit(':', 1)[1]) < 65536:
            sys.exit(f'"{item}": write the target as host=container:port, for example {host}=ui-user:80')
        routes[host] = upstream
    remove = [h.lower() for h in words(os.environ.get('REMOVE_INPUT', ''))]
    for h in remove:
        if not HOST.match(h):
            sys.exit(f'"{h}" is not a host name')
    clash = set(remove) & set(routes)
    if clash:
        sys.exit('Both added and removed: ' + ', '.join(sorted(clash)))
    if not routes and not remove:
        sys.exit('Nothing to do: give at least one route (or a host to remove).')

    template = (INFRA / 'nginx/site.conf.template').read_text()
    sites = INFRA / 'nginx/sites'
    sites.mkdir(parents=True, exist_ok=True)
    for old in sites.glob('*.conf'):
        old.unlink()
    OUT.mkdir(exist_ok=True)
    bases = sorted({base_of(h) for h in routes})
    for host, upstream in sorted(routes.items()):
        (sites / f'{host}.conf').write_text(template.replace('__HOST__', host).replace('__UPSTREAM__', upstream).replace('__BASE__', base_of(host)))
    for base in bases:
        cert, key = secret_names(base)
        if get(cert) and get(key):
            d = INFRA / 'certs' / base
            d.mkdir(parents=True, exist_ok=True)
            (d / 'fullchain.pem').write_text(pem(cert))
            (d / 'privkey.pem').write_text(pem(key))
            (d / 'privkey.pem').chmod(0o600)
    (OUT / 'bases.txt').write_text('\n'.join(bases) + ('\n' if bases else ''))
    (OUT / 'remove.txt').write_text('\n'.join(remove) + ('\n' if remove else ''))
    for host, upstream in sorted(routes.items()):
        print(f'add     {host} -> {upstream}')
    for h in remove:
        print(f'remove  {h}')


if __name__ == '__main__':
    main()

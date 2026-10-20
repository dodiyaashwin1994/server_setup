#!/usr/bin/env python3
"""Writes the certificates of the GitHub environment to infra/certs/<domain>/{fullchain,privkey}.pem (uploaded by the workflow; nothing else on the server is removed).

    DOMAINS_INPUT   extra domains besides SERVICE_DOMAIN, separated by commas or spaces
Secrets (base64, set by leezify_env/scripts/set-tls.sh): for SERVICE_DOMAIN TLS_CERT_PEM_BASE64 / TLS_KEY_PEM_BASE64; for another domain
TLS_<DOMAIN>_CERT_PEM_BASE64 / TLS_<DOMAIN>_KEY_PEM_BASE64 with dots and dashes written as underscores, in capitals (shop.net -> TLS_SHOP_NET_CERT_PEM_BASE64).
"""
import base64
import binascii
import json
import os
import re
import sys
from pathlib import Path

CERTS = Path(__file__).resolve().parent.parent / 'infra' / 'certs'
_SECRETS = json.loads(os.environ.get('ALL_SECRETS') or '{}')
DOMAIN = re.compile(r'^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$')


def get(name):
    return os.environ.get(name) or _SECRETS.get(name) or ''


def pem(name):
    try:
        text = base64.b64decode(get(name), validate=True).decode()
    except (binascii.Error, UnicodeDecodeError):
        sys.exit(f'{name} is not valid base64')
    if '-----BEGIN' not in text:
        sys.exit(f'{name} does not hold a PEM file')
    return text.strip() + '\n'


def main():
    main_domain = get('SERVICE_DOMAIN').strip().lower()
    domains = [d for d in re.split(r'[\s,;]+', (main_domain + ' ' + os.environ.get('DOMAINS_INPUT', '')).lower()) if d]
    if not domains:
        sys.exit('No domain: set SERVICE_DOMAIN or give domains.')
    for d in dict.fromkeys(domains):
        if not DOMAIN.match(d):
            sys.exit(f'"{d}" is not a domain')
        if d == main_domain:
            cert, key = 'TLS_CERT_PEM_BASE64', 'TLS_KEY_PEM_BASE64'
        else:
            tag = re.sub(r'[^A-Z0-9]', '_', d.upper())
            cert, key = f'TLS_{tag}_CERT_PEM_BASE64', f'TLS_{tag}_KEY_PEM_BASE64'
        if not (get(cert) and get(key)):
            sys.exit(f'No certificate for {d}: secrets {cert} and {key} are empty. Run leezify_env/scripts/set-tls.sh ... {"" if d == main_domain else d} and push-secrets.sh.')
        (CERTS / d).mkdir(parents=True, exist_ok=True)
        (CERTS / d / 'fullchain.pem').write_text(pem(cert))
        (CERTS / d / 'privkey.pem').write_text(pem(key))
        (CERTS / d / 'privkey.pem').chmod(0o600)
        print(f'certificate for {d}')


if __name__ == '__main__':
    main()

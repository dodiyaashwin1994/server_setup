#!/usr/bin/env bash
# nginx-route: publishes a container under a host name on this server's nginx edge. Installed as /usr/local/bin/nginx-route by the Setup infrastructure workflow.
# Any app can call it from its own deploy (over SSH); one file per host name is kept, so routes of other apps are never touched.
#
#   nginx-route add    --host app.example.com --target container:port [--cert FILE --key FILE] [--cert-domain example.com] [--max-body 15m] [--deny /internal,/admin] [--allow 203.0.113.0/24,198.51.100.7]
#   nginx-route remove --host app.example.com
#   nginx-route list
#   nginx-route check  [--host app.example.com] [--warn-days 14]
#
# The container must be on the docker network `public` (it does not have to be running yet: the name is looked up when a request arrives).
# Certificates: by default a free Let's Encrypt certificate is requested for the host the first time it is published (it must point to this server and port 80 must be reachable) and the
# certbot container renews it. A service may bring its own instead: --cert (the certificate, with its intermediates) and --key are checked (not expired, matches the key, covers the host) and installed in
# certs/<domain>/, where <domain> is the host's parent (app.example.com -> example.com) when the certificate is a wildcard for it, else the host itself. Without --cert the one already
# installed for that domain is used (--cert-domain names another one).
# --deny lists path prefixes the internet must not reach (they answer 404 at the edge; containers on the docker network still reach them directly).
# --allow lists the addresses (IPv4 / IPv6, with or without /mask) that may use this host; everyone else gets 403. Without it the host is open to everyone.
# check: is nginx running, does its configuration pass, and is the certificate of the host (of every host without --host) valid: parses, not expired (warns when it ends within
# --warn-days), covers the host, belongs to its key, has its intermediate certificate. Exits 1 when something is wrong.
# nginx is tested before it reloads; when it rejects the change the previous state is put back and the command fails.
set -euo pipefail
INFRA_DIR="${NGINX_ROUTE_INFRA:-__INFRA_DIR__}"
NGINX="${NGINX_ROUTE_NGINX:-docker exec nginx nginx}"
CERTBOT="${NGINX_ROUTE_CERTBOT:-docker compose -f $INFRA_DIR/docker-compose.yml --project-directory $INFRA_DIR run --rm --no-deps -T --entrypoint certbot certbot}"
SITES="$INFRA_DIR/nginx/sites"; CERTS="$INFRA_DIR/certs"; LE="$INFRA_DIR/letsencrypt"; TEMPLATE="$INFRA_DIR/nginx/site.conf.template"

die() { echo "nginx-route: $*" >&2; exit 1; }
usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
host=""; target=""; cert_domain=""; max_body="15m"; deny=""; cert_file=""; key_file=""; allow=""; warn_days="14"
while [ $# -gt 0 ]; do
  case "$1" in
    --host) host="${2:-}"; shift 2 ;;
    --target) target="${2:-}"; shift 2 ;;
    --cert-domain) cert_domain="${2:-}"; shift 2 ;;
    --max-body) max_body="${2:-}"; shift 2 ;;
    --deny) deny="${2:-}"; shift 2 ;;
    --allow) allow="${2:-}"; shift 2 ;;
    --warn-days) warn_days="${2:-}"; shift 2 ;;
    --cert) cert_file="${2:-}"; shift 2 ;;
    --key) key_file="${2:-}"; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done
host="$(printf '%s' "$host" | tr 'A-Z' 'a-z')"; cert_domain="$(printf '%s' "$cert_domain" | tr 'A-Z' 'a-z')"
HOST_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$'

mkdir -p "$SITES"
if command -v flock >/dev/null 2>&1; then      # two apps deploying at once must not edit the edge together
  exec 9>"$INFRA_DIR/.nginx-route.lock"
  flock -w 60 9 || die "another nginx-route is running"
fi

san_names() { openssl x509 -in "$1" -noout -text | awk '/Subject Alternative Name/ {getline; print}' | tr ',' '\n' | sed -n 's/.*DNS:[[:space:]]*//p' | tr -d ' ' || true; }

check_certificate() {   # cert, key, host, parent-or-empty: dies unless usable; prints the domain the certificate belongs in
  local cert="$1" key="$2" h="$3" par="$4" names
  [ -r "$cert" ] && [ -r "$key" ] || die "--cert / --key: cannot read the files"
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || die "--cert is not a certificate (PEM)"
  openssl x509 -in "$cert" -noout -checkend 0 >/dev/null || die "the certificate has expired"
  openssl x509 -in "$cert" -noout -checkend 1209600 >/dev/null || echo "nginx-route: warning: the certificate expires within 14 days" >&2
  [ "$(openssl x509 -in "$cert" -noout -pubkey | openssl sha256)" = "$(openssl pkey -in "$key" -pubout </dev/null 2>/dev/null | openssl sha256)" ] || die "the private key does not belong to the certificate (or it is passphrase protected)"
  names="$(san_names "$cert")"
  if [ -n "$par" ] && printf '%s\n' "$names" | grep -qx "\*.$par"; then echo "$par"
  elif printf '%s\n' "$names" | grep -qx "$h"; then echo "$h"
  else die "the certificate does not cover $h (it covers: $(printf '%s' "$names" | tr '\n' ' '))"; fi
}

env_value() { [ -f "$INFRA_DIR/.env" ] && grep "^$1=" "$INFRA_DIR/.env" | head -1 | cut -d= -f2- | tr -d "'" || true; }

obtain_certificate() {   # a Let's Encrypt certificate for $1 (HTTP-01: nginx answers the challenge on port 80 from /var/www/certbot)
  local h="$1" email staging_arg="" out
  email="${ACME_EMAIL:-$(env_value ACME_EMAIL)}"
  [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$ ]] || die "no e-mail address for Let's Encrypt: ACME_EMAIL is not in $INFRA_DIR/.env (run Setup infrastructure with acme_email)"
  [ "${ACME_STAGING:-$(env_value ACME_STAGING)}" = true ] && staging_arg="--staging"
  mkdir -p "$INFRA_DIR/acme-webroot" "$LE"
  echo "nginx-route: asking Let's Encrypt for a certificate for $h${staging_arg:+ (test service)} ..." >&2
  if ! out="$($CERTBOT certonly --webroot -w /var/www/certbot -d "$h" --email "$email" --agree-tos --no-eff-email --non-interactive --keep-until-expiring $staging_arg 2>&1)"; then
    printf '%s\n' "$out" | tail -15 >&2
    die "Let's Encrypt did not issue a certificate for $h. The name must point (A record) to this server and port 80 must be reachable from the internet; see the message above."
  fi
  [ -f "$LE/live/$h/fullchain.pem" ] || die "certbot reported success but $LE/live/$h/fullchain.pem is missing"
}

map_cert_path() {   # the path in a site file (as nginx sees it) -> the same file on this server
  case "$1" in
    /etc/nginx/certs/*) echo "$CERTS/${1#/etc/nginx/certs/}" ;;
    /etc/letsencrypt/*) echo "$LE/${1#/etc/letsencrypt/}" ;;
    *) echo "$1" ;;
  esac
}

nginx_running() {   # with a stand-in nginx command (tests) there is no container to look for
  [ -n "${NGINX_ROUTE_NGINX:-}" ] || docker ps --filter name=^nginx$ --filter status=running -q | grep -q .
}

CERT_BASE=""; CERT_BACKUP=""; CERT_HAD=""
apply() {   # test the configuration, reload; on failure restore $1 (the previous file, or empty when there was none) for host $host, and the previous certificate
  local backup="$1" file="$SITES/$host.conf"
  if out="$($NGINX -t 2>&1)"; then
    $NGINX -s reload
    return 0
  fi
  echo "$out" >&2
  if [ -s "$backup" ]; then cp "$backup" "$file"; else rm -f "$file"; fi
  if [ -n "$CERT_BASE" ]; then
    rm -rf "${CERTS:?}/$CERT_BASE"
    [ -n "$CERT_HAD" ] && cp -R "$CERT_BACKUP" "$CERTS/$CERT_BASE"
  fi
  die "nginx rejected the change; the previous state was put back"
}

case "$cmd" in
  add)
    [[ "$host" =~ $HOST_RE ]] || die "--host must be a host name such as app.example.com"
    [[ "$target" =~ ^[a-z0-9][a-z0-9_.-]*:[0-9]{1,5}$ ]] && [ "${target##*:}" -ge 1 ] && [ "${target##*:}" -le 65535 ] || die "--target must be container:port, e.g. ui-user:80"
    [[ "$max_body" =~ ^[0-9]+[kKmMgG]?$ ]] || die "--max-body must look like 15m"
    labels="$(printf '%s' "$host" | tr -cd '.' | wc -c)"
    parent="${host#*.}"
    [ -z "$cert_file$key_file" ] || { [ -n "$cert_file" ] && [ -n "$key_file" ]; } || die "--cert and --key go together"
    cert_conf_dir=""; acme_needed=""; cert_kind=""
    if [ -n "$cert_file" ]; then
      base="$(check_certificate "$cert_file" "$key_file" "$host" "$([ "$labels" -ge 2 ] && echo "$parent")")" || exit 1
      [ -z "$cert_domain" ] || base="$cert_domain"
      cert_conf_dir="/etc/nginx/certs/$base"; cert_kind="installed now"
    else
      if [ -n "$cert_domain" ]; then base="$cert_domain"
      elif [ "$labels" -ge 2 ] && [ -f "$CERTS/$parent/fullchain.pem" ]; then base="$parent"
      else base="$host"; fi
      [[ "$base" =~ $HOST_RE ]] || die "--cert-domain is not a domain"
      if [ -f "$CERTS/$base/fullchain.pem" ] && [ -f "$CERTS/$base/privkey.pem" ]; then cert_conf_dir="/etc/nginx/certs/$base"; cert_kind="certificate files of $base"
      elif [ -n "$cert_domain" ]; then die "no certificate for $base on this server (installed: $(ls "$CERTS" 2>/dev/null | tr '\n' ' ')): pass --cert and --key"
      else
        base="$host"; cert_conf_dir="/etc/letsencrypt/live/$host"; cert_kind="Let's Encrypt"
        [ -f "$LE/live/$host/fullchain.pem" ] || acme_needed=1
      fi
    fi
    deny_conf=""
    if [ -n "$deny" ]; then
      [[ "$deny" =~ ^/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*(,/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*)*$ ]] || die "--deny must look like /internal,/admin"
      alt="$(printf '%s' "$deny" | sed 's|^/||; s|,/|\||g')"
      deny_conf="    location ~ ^/($alt)(/|\$) { return 404; }"
    fi
    allow_conf=""
    if [ -n "$allow" ]; then
      IFS=',' read -ra addrs <<< "$allow"
      for a in "${addrs[@]}"; do
        [[ "$a" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]] || die "--allow: \"$a\" is not an IP address or network"
        allow_conf+="    allow $a;"$'\n'
      done
      allow_conf+="    deny all;"
    fi
    [ -f "$TEMPLATE" ] || die "$TEMPLATE is missing: run the Setup infrastructure workflow"
    [ -z "$acme_needed" ] || obtain_certificate "$host"
    backup="$(mktemp)"; CERT_BACKUP="$(mktemp -d)"; trap 'rm -rf "$backup" "$CERT_BACKUP"' EXIT
    [ -f "$SITES/$host.conf" ] && cp "$SITES/$host.conf" "$backup" || : > "$backup"
    if [ -n "$cert_file" ]; then
      CERT_BASE="$base"; [ -d "$CERTS/$base" ] && { CERT_HAD=1; cp -R "$CERTS/$base/." "$CERT_BACKUP/"; }
      mkdir -p "$CERTS/$base"
      cp "$cert_file" "$CERTS/$base/fullchain.pem"; cp "$key_file" "$CERTS/$base/privkey.pem"; chmod 600 "$CERTS/$base/privkey.pem"
    fi
    sed -e "s|__HOST__|$host|g" -e "s|__UPSTREAM__|$target|g" -e "s|__CERT_DIR__|$cert_conf_dir|g" -e "s|__MAX_BODY__|$max_body|g" "$TEMPLATE" \
      | DENY_CONF="$deny_conf" ALLOW_CONF="$allow_conf" awk '/__ALLOW__/ { if (ENVIRON["ALLOW_CONF"] != "") print ENVIRON["ALLOW_CONF"]; next } /__DENY__/ { if (ENVIRON["DENY_CONF"] != "") print ENVIRON["DENY_CONF"]; next } { print }' > "$SITES/$host.conf.new"
    mv "$SITES/$host.conf.new" "$SITES/$host.conf"
    apply "$backup"
    echo "nginx-route: $host -> $target (certificate: $cert_kind)"
    ;;
  remove)
    [[ "$host" =~ $HOST_RE ]] || die "--host must be a host name"
    [ -f "$SITES/$host.conf" ] || { echo "nginx-route: $host has no route (nothing to remove)"; exit 0; }
    backup="$(mktemp)"; trap 'rm -f "$backup"' EXIT
    cp "$SITES/$host.conf" "$backup"; rm -f "$SITES/$host.conf"
    apply "$backup"
    echo "nginx-route: removed $host"
    ;;
  list)
    for f in "$SITES"/*.conf; do [ -f "$f" ] && head -1 "$f" | sed 's/^# //'; done | sort
    ;;
  check)
    [[ "$warn_days" =~ ^[0-9]{1,4}$ ]] || die "--warn-days must be a number of days"
    fails=0
    say() { printf '%-5s %s\n' "$1" "$2"; [ "$1" != FAIL ] || fails=$((fails + 1)); }
    if nginx_running; then say OK "nginx is running"; else say FAIL "nginx is not running (docker ps shows no running container named nginx)"; fi
    if out="$($NGINX -t 2>&1)"; then say OK "nginx configuration test passed"; else say FAIL "nginx configuration test failed: $(printf '%s' "$out" | tail -1)"; fi
    hosts=()
    if [ -n "$host" ]; then hosts=("$host"); else for f in "$SITES"/*.conf; do [ -f "$f" ] && hosts+=("$(basename "$f" .conf)"); done; fi
    [ ${#hosts[@]} -gt 0 ] || say WARN "no host is published yet"
    for h in ${hosts[@]+"${hosts[@]}"}; do
      conf="$SITES/$h.conf"
      [ -f "$conf" ] || { say FAIL "$h: no site file ($conf)"; continue; }
      cert="$(map_cert_path "$(awk '/^[[:space:]]*ssl_certificate[[:space:]]/ {print $2}' "$conf" | tr -d ';')")"
      key="$(map_cert_path "$(awk '/^[[:space:]]*ssl_certificate_key[[:space:]]/ {print $2}' "$conf" | tr -d ';')")"
      if [ ! -f "$cert" ] || [ ! -f "$key" ]; then say FAIL "$h: certificate files are missing ($cert)"; continue; fi
      if ! openssl x509 -in "$cert" -noout >/dev/null 2>&1; then say FAIL "$h: $cert is not a readable certificate"; continue; fi
      ends="$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)"
      if ! openssl x509 -in "$cert" -noout -checkend 0 >/dev/null; then say FAIL "$h: the certificate expired on $ends"
      elif ! openssl x509 -in "$cert" -noout -checkend $((warn_days * 86400)) >/dev/null; then say WARN "$h: the certificate expires on $ends (within $warn_days days): renew it"
      else say OK "$h: certificate valid until $ends"; fi
      names="$(san_names "$cert")"; parent="${h#*.}"
      if printf '%s\n' "$names" | grep -qx "$h" || printf '%s\n' "$names" | grep -qx "\*.$parent"; then say OK "$h: the certificate covers the host"
      else say FAIL "$h: the certificate does not cover the host (it covers: $(printf '%s' "$names" | tr '\n' ' '))"; fi
      if [ "$(openssl x509 -in "$cert" -noout -pubkey | openssl sha256)" = "$(openssl pkey -in "$key" -pubout </dev/null 2>/dev/null | openssl sha256)" ]; then say OK "$h: the private key matches the certificate"
      else say FAIL "$h: the private key does not belong to the certificate"; fi
      if openssl x509 -in "$cert" -noout -issuer | grep -qi "staging"; then say WARN "$h: issued by the Let's Encrypt test service: browsers will not trust it (run Setup infrastructure with acme_staging off and publish the host again)"; fi
      if [ "$(grep -c 'BEGIN CERTIFICATE' "$cert")" -lt 2 ] && [ "$(openssl x509 -in "$cert" -noout -subject_hash)" != "$(openssl x509 -in "$cert" -noout -issuer_hash)" ]; then
        say WARN "$h: the file has no intermediate certificate: some browsers and tools will not trust it (add the CA bundle after the certificate)"
      fi
    done
    [ "$fails" -eq 0 ] || exit 1
    ;;
  *) usage ;;
esac

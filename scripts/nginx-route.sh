#!/usr/bin/env bash
# nginx-route: publishes a container under a host name on this server's nginx edge. Installed as /usr/local/bin/nginx-route by the Setup infrastructure workflow.
# Any app can call it from its own deploy (over SSH); one file per host name is kept, so routes of other apps are never touched.
#
#   nginx-route add    --host app.example.com --target container:port [--cert FILE --key FILE] [--cert-domain example.com] [--max-body 15m] [--deny /internal,/admin] [--allow 203.0.113.0/24,198.51.100.7]
#   nginx-route remove --host app.example.com
#   nginx-route list
#   nginx-route check  [--host app.example.com] [--warn-days 30]
#
# The container must be on the docker network `public` (it does not have to be running yet: the name is looked up when a request arrives).
# The certificate comes with the service: --cert (the certificate, with its intermediates) and --key are checked (not expired, matches the key, covers the host) and installed in
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
SITES="$INFRA_DIR/nginx/sites"; CERTS="$INFRA_DIR/certs"; TEMPLATE="$INFRA_DIR/nginx/site.conf.template"

die() { echo "nginx-route: $*" >&2; exit 1; }
usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
host=""; target=""; cert_domain=""; max_body="15m"; deny=""; cert_file=""; key_file=""; allow=""; warn_days="30"
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
    if [ -n "$cert_file" ]; then
      base="$(check_certificate "$cert_file" "$key_file" "$host" "$([ "$labels" -ge 2 ] && echo "$parent")")" || exit 1
      [ -z "$cert_domain" ] || base="$cert_domain"
    elif [ -n "$cert_domain" ]; then base="$cert_domain"
    elif [ "$labels" -ge 2 ] && [ -f "$CERTS/$parent/fullchain.pem" ]; then base="$parent"
    else base="$host"; fi
    [[ "$base" =~ $HOST_RE ]] || die "--cert-domain is not a domain"
    if [ -z "$cert_file" ] && { [ ! -f "$CERTS/$base/fullchain.pem" ] || [ ! -f "$CERTS/$base/privkey.pem" ]; }; then
      die "no certificate for $base on this server (installed: $(ls "$CERTS" 2>/dev/null | tr '\n' ' ')). Deploy with the service's certificate (TLS_CERT_PEM_BASE64 / TLS_KEY_PEM_BASE64) or pass --cert and --key."
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
    backup="$(mktemp)"; CERT_BACKUP="$(mktemp -d)"; trap 'rm -rf "$backup" "$CERT_BACKUP"' EXIT
    [ -f "$SITES/$host.conf" ] && cp "$SITES/$host.conf" "$backup" || : > "$backup"
    if [ -n "$cert_file" ]; then
      CERT_BASE="$base"; [ -d "$CERTS/$base" ] && { CERT_HAD=1; cp -R "$CERTS/$base/." "$CERT_BACKUP/"; }
      mkdir -p "$CERTS/$base"
      cp "$cert_file" "$CERTS/$base/fullchain.pem"; cp "$key_file" "$CERTS/$base/privkey.pem"; chmod 600 "$CERTS/$base/privkey.pem"
    fi
    sed -e "s|__HOST__|$host|g" -e "s|__UPSTREAM__|$target|g" -e "s|__BASE__|$base|g" -e "s|__MAX_BODY__|$max_body|g" "$TEMPLATE" \
      | DENY_CONF="$deny_conf" ALLOW_CONF="$allow_conf" awk '/__ALLOW__/ { if (ENVIRON["ALLOW_CONF"] != "") print ENVIRON["ALLOW_CONF"]; next } /__DENY__/ { if (ENVIRON["DENY_CONF"] != "") print ENVIRON["DENY_CONF"]; next } { print }' > "$SITES/$host.conf.new"
    mv "$SITES/$host.conf.new" "$SITES/$host.conf"
    apply "$backup"
    echo "nginx-route: $host -> $target (certificate of $base$([ -n "$cert_file" ] && echo ", installed now"))"
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
      cert="$CERTS/$(awk '/^[[:space:]]*ssl_certificate[[:space:]]/ {print $2}' "$conf" | tr -d ';' | sed 's|^/etc/nginx/certs/||')"
      key="$CERTS/$(awk '/^[[:space:]]*ssl_certificate_key[[:space:]]/ {print $2}' "$conf" | tr -d ';' | sed 's|^/etc/nginx/certs/||')"
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
      if [ "$(grep -c 'BEGIN CERTIFICATE' "$cert")" -lt 2 ] && [ "$(openssl x509 -in "$cert" -noout -subject_hash)" != "$(openssl x509 -in "$cert" -noout -issuer_hash)" ]; then
        say WARN "$h: the file has no intermediate certificate: some browsers and tools will not trust it (add the CA bundle after the certificate)"
      fi
    done
    [ "$fails" -eq 0 ] || exit 1
    ;;
  *) usage ;;
esac

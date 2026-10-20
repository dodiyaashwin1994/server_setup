#!/usr/bin/env bash
# nginx-route: publishes a container under a host name on this server's nginx edge. Installed as /usr/local/bin/nginx-route by the Setup infrastructure workflow.
# Any app can call it from its own deploy (over SSH); one file per host name is kept, so routes of other apps are never touched.
#
#   nginx-route add    --host app.example.com --target container:port [--cert-domain example.com] [--max-body 15m]
#   nginx-route remove --host app.example.com
#   nginx-route list
#
# The container must be on the docker network `public` (it does not have to be running yet: the name is looked up when a request arrives).
# The certificate is the wildcard of the host's parent domain (app.example.com -> certs/example.com/), or of the host itself; --cert-domain names another one.
# nginx is tested before it reloads; when it rejects the change the previous state is put back and the command fails.
set -euo pipefail
INFRA_DIR="${NGINX_ROUTE_INFRA:-__INFRA_DIR__}"
NGINX="${NGINX_ROUTE_NGINX:-docker exec nginx nginx}"
SITES="$INFRA_DIR/nginx/sites"; CERTS="$INFRA_DIR/certs"; TEMPLATE="$INFRA_DIR/nginx/site.conf.template"

die() { echo "nginx-route: $*" >&2; exit 1; }
usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
host=""; target=""; cert_domain=""; max_body="15m"
while [ $# -gt 0 ]; do
  case "$1" in
    --host) host="${2:-}"; shift 2 ;;
    --target) target="${2:-}"; shift 2 ;;
    --cert-domain) cert_domain="${2:-}"; shift 2 ;;
    --max-body) max_body="${2:-}"; shift 2 ;;
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

apply() {   # test the configuration, reload; on failure restore $1 (the previous file, or empty when there was none) for host $host
  local backup="$1" file="$SITES/$host.conf"
  if out="$($NGINX -t 2>&1)"; then
    $NGINX -s reload
    return 0
  fi
  echo "$out" >&2
  if [ -s "$backup" ]; then cp "$backup" "$file"; else rm -f "$file"; fi
  die "nginx rejected the change; the previous state was put back"
}

case "$cmd" in
  add)
    [[ "$host" =~ $HOST_RE ]] || die "--host must be a host name such as app.example.com"
    [[ "$target" =~ ^[a-z0-9][a-z0-9_.-]*:[0-9]{1,5}$ ]] && [ "${target##*:}" -ge 1 ] && [ "${target##*:}" -le 65535 ] || die "--target must be container:port, e.g. ui-user:80"
    [[ "$max_body" =~ ^[0-9]+[kKmMgG]?$ ]] || die "--max-body must look like 15m"
    labels="$(printf '%s' "$host" | tr -cd '.' | wc -c)"
    parent="${host#*.}"
    if [ -n "$cert_domain" ]; then base="$cert_domain"
    elif [ "$labels" -ge 2 ] && [ -f "$CERTS/$parent/fullchain.pem" ]; then base="$parent"
    else base="$host"; fi
    [[ "$base" =~ $HOST_RE ]] || die "--cert-domain is not a domain"
    if [ ! -f "$CERTS/$base/fullchain.pem" ] || [ ! -f "$CERTS/$base/privkey.pem" ]; then
      die "no certificate for $base on this server (installed: $(ls "$CERTS" 2>/dev/null | tr '\n' ' ')). Install it with the Setup infrastructure workflow first."
    fi
    [ -f "$TEMPLATE" ] || die "$TEMPLATE is missing: run the Setup infrastructure workflow"
    backup="$(mktemp)"; trap 'rm -f "$backup"' EXIT
    [ -f "$SITES/$host.conf" ] && cp "$SITES/$host.conf" "$backup" || : > "$backup"
    sed -e "s|__HOST__|$host|g" -e "s|__UPSTREAM__|$target|g" -e "s|__BASE__|$base|g" -e "s|__MAX_BODY__|$max_body|g" "$TEMPLATE" > "$SITES/$host.conf.new"
    mv "$SITES/$host.conf.new" "$SITES/$host.conf"
    apply "$backup"
    echo "nginx-route: $host -> $target (certificate of $base)"
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
  *) usage ;;
esac

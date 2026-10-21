#!/usr/bin/env bash
# Makes sure the MySQL accounts are right after MySQL has been (re)deployed. Safe to run again. Run on the server in infra/ with the values of .env in the environment (the workflow does).
#
#   service user   MYSQL_USERNAME (root, or another name that is created here with every privilege: the services create one database per account).
#   remote login   MYSQL_REMOTE_USER, only for the addresses in MYSQL_REMOTE_IPS (empty list = no remote login, the account is removed).
#
# When remote addresses are given the MySQL port is open to the internet (docker publishes it around the firewall), so MySQL itself must refuse everyone else: it checks the address of the
# caller BEFORE the password, so a stranger gets "Host ... is not allowed" and never reaches a password prompt. For that, `root` and the service user are limited to the docker network `public`
# (where the services run; they stop being usable from anywhere else) and the remote login is limited to the listed addresses.
set -euo pipefail
SERVICE_USER="${MYSQL_USERNAME:-root}"; REMOTE_USER="${MYSQL_REMOTE_USER:-dba}"; REMOTE_IPS="${MYSQL_REMOTE_IPS:-}"
NAME_RE='^[A-Za-z0-9_]{1,32}$'
[[ "$SERVICE_USER" =~ $NAME_RE ]] || { echo "MYSQL_USERNAME must be letters, digits and _ (at most 32)" >&2; exit 1; }
[[ "$REMOTE_USER" =~ $NAME_RE ]] || { echo "MYSQL_REMOTE_USER must be letters, digits and _ (at most 32)" >&2; exit 1; }
[ "$REMOTE_USER" != root ] && [ "$REMOTE_USER" != "$SERVICE_USER" ] || { echo "MYSQL_REMOTE_USER must differ from root and the service user" >&2; exit 1; }
for v in MYSQL_PASSWORD MYSQL_REMOTE_PASSWORD; do [[ "${!v:-}" != *\\* && "${!v:-}" != *\'* ]] || { echo "$v must not contain a backslash or a single quote" >&2; exit 1; }; done

host_of() {   # 203.0.113.7 -> 203.0.113.7 ; 203.0.113.0/24 -> 203.0.113.0/255.255.255.0 (how MySQL writes a network in an account's host)
  python3 - "$1" <<'PY'
import ipaddress, sys
n = ipaddress.ip_network(sys.argv[1], strict=False)
print(str(n.network_address) if n.prefixlen == 32 else f'{n.network_address}/{n.netmask}')
PY
}

remote_hosts=(); for ip in ${REMOTE_IPS//,/ }; do remote_hosts+=("$(host_of "$ip")"); done

docker_hosts=()
if [ ${#remote_hosts[@]} -gt 0 ]; then
  subnets="${DOCKER_SUBNETS:-$(docker network inspect public -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}')}"
  for s in $subnets; do [[ "$s" == *.* ]] && docker_hosts+=("$(host_of "$s")"); done
  [ ${#docker_hosts[@]} -gt 0 ] || { echo "Cannot find the IPv4 subnet of the docker network 'public': not opening MySQL to the internet without it" >&2; exit 1; }
  [ -n "${MYSQL_REMOTE_PASSWORD:-}" ] || { echo "MYSQL_REMOTE_PASSWORD is empty" >&2; exit 1; }
fi

# the password goes in through the client's environment and the statements through stdin: neither shows in a process list
MYSQL_CMD="${MYSQL_CMD:-docker compose exec -T -e MYSQL_PWD=${MYSQL_ROOT_PASSWORD} mysql mysql -uroot}"

account() {   # user host password: create it, set the password, give every privilege
  printf "CREATE USER IF NOT EXISTS '%s'@'%s' IDENTIFIED BY '%s';\nALTER USER '%s'@'%s' IDENTIFIED BY '%s';\nGRANT ALL PRIVILEGES ON *.* TO '%s'@'%s' WITH GRANT OPTION;\n" "$1" "$2" "$3" "$1" "$2" "$3" "$1" "$2"
}

sql=""
if [ ${#remote_hosts[@]} -gt 0 ]; then
  for h in "${docker_hosts[@]}"; do
    sql+="$(account root "$h" "$MYSQL_ROOT_PASSWORD")"$'\n'
    [ "$SERVICE_USER" = root ] || sql+="$(account "$SERVICE_USER" "$h" "$MYSQL_PASSWORD")"$'\n'
  done
  sql+="DROP USER IF EXISTS 'root'@'%';"$'\n'
  [ "$SERVICE_USER" = root ] || sql+="DROP USER IF EXISTS '${SERVICE_USER}'@'%';"$'\n'
  for h in "${remote_hosts[@]}"; do sql+="$(account "$REMOTE_USER" "$h" "$MYSQL_REMOTE_PASSWORD")"$'\n'; done
else
  [ "$SERVICE_USER" = root ] || sql+="$(account "$SERVICE_USER" '%' "$MYSQL_PASSWORD")"$'\n'
fi

# remote accounts that are no longer wanted (another address, or remote access switched off)
existing="$($MYSQL_CMD -N -B -e "SELECT host FROM mysql.user WHERE user='${REMOTE_USER}'")"
while IFS= read -r h; do
  [ -n "$h" ] || continue
  keep=""; for w in ${remote_hosts[@]+"${remote_hosts[@]}"}; do [ "$w" = "$h" ] && keep=1; done
  [ -n "$keep" ] || sql+="DROP USER IF EXISTS '${REMOTE_USER}'@'${h}';"$'\n'
done <<< "$existing"
sql+="FLUSH PRIVILEGES;"

$MYSQL_CMD <<< "$sql"
if [ ${#remote_hosts[@]} -gt 0 ]; then
  echo "mysql: port open only to ${REMOTE_IPS} (login ${REMOTE_USER}); root and ${SERVICE_USER} only from the docker network (${docker_hosts[*]})"
else
  echo "mysql: no remote login (port on 127.0.0.1); service user ${SERVICE_USER}"
fi

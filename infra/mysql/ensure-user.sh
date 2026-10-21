#!/usr/bin/env bash
# Makes sure the MySQL accounts are right after MySQL has been (re)deployed or its access list changed. Safe to run again. Run on the server in infra/ with the values of .env in the
# environment (the workflow does): MYSQL_USERNAME, MYSQL_PASSWORD, MYSQL_ROOT_PASSWORD, MYSQL_REMOTE_IPS.
#
#   service user   MYSQL_USERNAME: root, or another name that is created here with every privilege (the services create one database per account).
#   remote access  MYSQL_REMOTE_IPS: the addresses that may log in from outside, as root / the service user, with the normal password. Empty = nobody from outside.
#
# With addresses the MySQL port is open to the internet (docker publishes it around the firewall), so MySQL itself refuses everyone else: it checks the address of the caller BEFORE the
# password, so a stranger gets "Host ... is not allowed to connect" and never reaches a password prompt. root and the service user are therefore only valid from the docker network `public`
# (where the services run), from the machine itself and from the listed addresses; the "any address" (%) accounts are removed.
set -euo pipefail
SERVICE_USER="${MYSQL_USERNAME:-root}"; REMOTE_IPS="${MYSQL_REMOTE_IPS:-}"
[[ "$SERVICE_USER" =~ ^[A-Za-z0-9_]{1,32}$ ]] || { echo "MYSQL_USERNAME must be letters, digits and _ (at most 32)" >&2; exit 1; }
[[ "${MYSQL_PASSWORD:-}" != *\\* && "${MYSQL_PASSWORD:-}" != *\'* ]] || { echo "MYSQL_PASSWORD must not contain a backslash or a single quote" >&2; exit 1; }

host_of() {   # 203.0.113.7 -> 203.0.113.7 ; 203.0.113.0/24 -> 203.0.113.0/255.255.255.0 (how MySQL writes a network in an account's host)
  python3 - "$1" <<'PY'
import ipaddress, sys
n = ipaddress.ip_network(sys.argv[1], strict=False)
print(str(n.network_address) if n.prefixlen == 32 else f'{n.network_address}/{n.netmask}')
PY
}

remote_hosts=(); for ip in ${REMOTE_IPS//,/ }; do remote_hosts+=("$(host_of "$ip")"); done
docker_hosts=()
subnets="${DOCKER_SUBNETS-$(docker network inspect public -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)}"
for s in $subnets; do [[ "$s" == *.* ]] && docker_hosts+=("$(host_of "$s")"); done
if [ ${#remote_hosts[@]} -gt 0 ] && [ ${#docker_hosts[@]} -eq 0 ]; then
  echo "Cannot find the IPv4 subnet of the docker network 'public': not opening MySQL to the internet without it (the services could not log in any more)" >&2; exit 1
fi

# the password goes in through the client's environment and the statements through stdin: neither shows in a process list
MYSQL_CMD="${MYSQL_CMD:-docker compose exec -T -e MYSQL_PWD=${MYSQL_ROOT_PASSWORD} mysql mysql -uroot}"

account() {   # user host password: create it, set the password, give every privilege
  printf "CREATE USER IF NOT EXISTS '%s'@'%s' IDENTIFIED BY '%s';\nALTER USER '%s'@'%s' IDENTIFIED BY '%s';\nGRANT ALL PRIVILEGES ON *.* TO '%s'@'%s' WITH GRANT OPTION;\n" "$1" "$2" "$3" "$1" "$2" "$3" "$1" "$2"
}
in_list() { local x="$1"; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

users=(root); [ "$SERVICE_USER" = root ] || users+=("$SERVICE_USER")
sql=""
for u in "${users[@]}"; do
  pw="$MYSQL_ROOT_PASSWORD"; [ "$u" = root ] || pw="$MYSQL_PASSWORD"
  if [ ${#remote_hosts[@]} -gt 0 ]; then desired=("${docker_hosts[@]}" "${remote_hosts[@]}"); else desired=(${docker_hosts[@]+"${docker_hosts[@]}"}); fi
  if [ "$u" != root ] && [ ${#remote_hosts[@]} -eq 0 ]; then desired+=('%'); fi          # port closed: the service user keeps working from any container
  for h in ${desired[@]+"${desired[@]}"}; do sql+="$(account "$u" "$h" "$pw")"$'\n'; done
  # accounts of this user that are no longer wanted: the "any address" one when the port is open, addresses that left the list. The machine itself (localhost) always stays.
  existing="$($MYSQL_CMD -N -B -e "SELECT host FROM mysql.user WHERE user='${u}'")"
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    [ "$h" = localhost ] && continue
    in_list "$h" ${desired[@]+"${desired[@]}"} && continue
    [ "$h" = '%' ] && [ ${#remote_hosts[@]} -eq 0 ] && continue                          # port closed: leave an existing "any address" account alone
    sql+="DROP USER IF EXISTS '${u}'@'${h}';"$'\n'
  done <<< "$existing"
done
sql+="FLUSH PRIVILEGES;"

$MYSQL_CMD <<< "$sql"
if [ ${#remote_hosts[@]} -gt 0 ]; then
  echo "mysql: ${users[*]} may log in from: ${REMOTE_IPS}, the docker network (${docker_hosts[*]}) and this machine. Nobody else is let in."
else
  echo "mysql: no login from outside (${users[*]}); service user ${SERVICE_USER}"
fi

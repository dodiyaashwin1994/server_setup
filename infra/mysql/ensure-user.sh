#!/usr/bin/env bash
# Makes sure the MySQL user the services log in with exists with the right password and rights. Safe to run again.
# The MySQL image only creates `root`, and only on the first start; a different user (MYSQL_USERNAME) is created here. The services create one database per account, so it gets every privilege.
# Run on the server in infra/ with the values of .env in the environment (the workflow does): MYSQL_USERNAME, MYSQL_PASSWORD, MYSQL_ROOT_PASSWORD.
set -euo pipefail
USER_NAME="${MYSQL_USERNAME:-root}"
[ "$USER_NAME" = root ] && { echo "mysql user: root (nothing to create)"; exit 0; }
[[ "$USER_NAME" =~ ^[A-Za-z0-9_]{1,32}$ ]] || { echo "MYSQL_USERNAME must be letters, digits and _ (at most 32)" >&2; exit 1; }
[[ "${MYSQL_PASSWORD:-}" != *\\* ]] || { echo "MYSQL_PASSWORD must not contain a backslash" >&2; exit 1; }
# the password goes in through the client's environment and the statements through stdin: neither shows in a process list
MYSQL_CMD="${MYSQL_CMD:-docker compose exec -T -e MYSQL_PWD=${MYSQL_ROOT_PASSWORD} mysql mysql -uroot}"
$MYSQL_CMD <<SQL
CREATE USER IF NOT EXISTS '${USER_NAME}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
ALTER USER '${USER_NAME}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO '${USER_NAME}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
echo "mysql user: ${USER_NAME} ready"

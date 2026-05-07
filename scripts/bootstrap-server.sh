#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/saas}"
INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
PREPARE_ALL="${PREPARE_ALL:-true}"
SETUP_NGINX="${SETUP_NGINX:-$PREPARE_ALL}"
SETUP_MYSQL="${SETUP_MYSQL:-$PREPARE_ALL}"
SETUP_RABBITMQ="${SETUP_RABBITMQ:-$PREPARE_ALL}"
SETUP_REDIS="${SETUP_REDIS:-$PREPARE_ALL}"
SETUP_SERVICES="${SETUP_SERVICES:-$PREPARE_ALL}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script as root or with sudo." >&2
  exit 1
fi

apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release ufw rsync

if [ "$INSTALL_DOCKER" = "true" ]; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes --batch -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker

  docker network inspect public >/dev/null 2>&1 || docker network create public
fi

mkdir -p "$DEPLOY_ROOT"

if [ "$SETUP_NGINX" = "true" ]; then
  mkdir -p "${DEPLOY_ROOT}/infra/nginx/conf.d"
  mkdir -p "${DEPLOY_ROOT}/infra/nginx/locations"
  mkdir -p "${DEPLOY_ROOT}/infra/nginx/certs"
  mkdir -p "${DEPLOY_ROOT}/infra/nginx/html"
  mkdir -p "${DEPLOY_ROOT}/infra/nginx/logs"
  mkdir -p "${DEPLOY_ROOT}/infra/certbot/conf"
  mkdir -p "${DEPLOY_ROOT}/infra/certbot/www"
fi

[ "$SETUP_MYSQL" = "true" ] && mkdir -p "${DEPLOY_ROOT}/infra/mysql/initdb"
[ "$SETUP_RABBITMQ" = "true" ] && mkdir -p "${DEPLOY_ROOT}/infra/rabbitmq"
[ "$SETUP_REDIS" = "true" ] && mkdir -p "${DEPLOY_ROOT}/infra/redis"

[ "$SETUP_MYSQL" = "true" ] && mkdir -p "${DEPLOY_ROOT}/mysql"
[ "$SETUP_RABBITMQ" = "true" ] && mkdir -p "${DEPLOY_ROOT}/rabbitmq"
[ "$SETUP_REDIS" = "true" ] && mkdir -p "${DEPLOY_ROOT}/redis"
[ "$SETUP_NGINX" = "true" ] && mkdir -p "${DEPLOY_ROOT}/nginx/html"

if [ "$SETUP_SERVICES" = "true" ]; then
  mkdir -p \
    "${DEPLOY_ROOT}/authorization" \
    "${DEPLOY_ROOT}/workflow" \
    "${DEPLOY_ROOT}/notification" \
    "${DEPLOY_ROOT}/audit" \
    "${DEPLOY_ROOT}/document"
fi

ufw allow OpenSSH || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
ufw allow 3306/tcp || true
ufw allow 6379/tcp || true
ufw allow 5672/tcp || true
ufw allow 15672/tcp || true

ufw allow 5672/tcp || true

echo "Server bootstrap complete."

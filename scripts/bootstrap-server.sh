#!/usr/bin/env bash
# Prepares a fresh Ubuntu/Debian server: Docker, the shared network, folders and a firewall that opens SSH, HTTP and HTTPS only.
# MySQL, Redis and RabbitMQ are not opened to the internet.
set -euo pipefail
DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/leezify}"
[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release ufw rsync

if ! command -v docker >/dev/null 2>&1; then
  . /etc/os-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor --yes --batch -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
docker network inspect public >/dev/null 2>&1 || docker network create public

mkdir -p "$DEPLOY_ROOT/infra" "$DEPLOY_ROOT/app"

ufw allow OpenSSH || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
ufw --force enable || true

echo "Server bootstrap complete."

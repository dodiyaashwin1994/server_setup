#!/usr/bin/env bash
# Writes the deploy key from a secret to ~/.ssh and checks that it is usable.
set -euo pipefail
mkdir -p ~/.ssh && chmod 700 ~/.ssh
key_path="${SSH_KEY_PATH:-$HOME/.ssh/deploy_key}"
if [ -n "${SECRET_PRIVATE_KEY_BASE64:-}" ]; then
  printf '%s' "$SECRET_PRIVATE_KEY_BASE64" | tr -d '\r\n ' | base64 -d > "$key_path"
elif [ -n "${SECRET_PRIVATE_KEY:-}" ]; then
  printf '%s\n' "$SECRET_PRIVATE_KEY" | sed 's/\r$//' > "$key_path"
else
  echo "Set the SSH_PRIVATE_KEY secret (or SSH_PRIVATE_KEY_BASE64)." >&2
  exit 1
fi
chmod 600 "$key_path"
ssh-keygen -y -f "$key_path" >/dev/null 2>&1 || { echo "The SSH private key is invalid or passphrase protected." >&2; exit 1; }
ssh-keygen -lf <(ssh-keygen -y -f "$key_path")

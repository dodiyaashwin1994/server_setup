#!/usr/bin/env bash
set -euo pipefail

mkdir -p ~/.ssh
chmod 700 ~/.ssh

key_path="${SSH_KEY_PATH:-$HOME/.ssh/bootstrap_key}"
raw_key="${SECRET_PRIVATE_KEY:-}"
base64_key="${SECRET_PRIVATE_KEY_BASE64:-}"
input_key="${INPUT_PRIVATE_KEY:-}"

if [ -n "$base64_key" ]; then
  printf '%s' "$base64_key" | tr -d '\r\n ' | base64 -d > "$key_path"
elif [ -n "$raw_key" ]; then
  printf '%s\n' "$raw_key" | sed 's/\r$//' > "$key_path"
elif [ -n "$input_key" ]; then
  printf '%s\n' "$input_key" | sed 's/\r$//' > "$key_path"
else
  echo "Provide BOOTSTRAP_SSH_PRIVATE_KEY_BASE64, BOOTSTRAP_SSH_PRIVATE_KEY, or ssh_private_key input." >&2
  exit 1
fi

chmod 600 "$key_path"

if ! ssh-keygen -y -f "$key_path" >/dev/null 2>&1; then
  echo "The configured SSH private key is invalid or passphrase protected." >&2
  echo "Use an unencrypted private key, preferably stored as BOOTSTRAP_SSH_PRIVATE_KEY_BASE64." >&2
  exit 1
fi

ssh-keygen -y -f "$key_path" > "$key_path.pub"
ssh-keygen -lf "$key_path.pub"

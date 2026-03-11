#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

if [[ -z "${SSH_TOOL_TOKEN:-}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    export SSH_TOOL_TOKEN="$(openssl rand -hex 24)"
  else
    export SSH_TOOL_TOKEN="$(date +%s)-$RANDOM-$RANDOM"
  fi
fi

echo "SSH Tool token (x-ssh-tool-token): ${SSH_TOOL_TOKEN}"
echo "Opening http://127.0.0.1:3000 ..."
open "http://127.0.0.1:3000" >/dev/null 2>&1 || true

sudo -E node app.js


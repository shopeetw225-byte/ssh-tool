#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

SUPPORT_PUB="${SSH_TOOL_SUPPORT_PUB:-${ROOT_DIR}/keys/support.pub}"
if [[ ! -f "${SUPPORT_PUB}" ]]; then
  echo "Missing support public key file: ${SUPPORT_PUB}"
  echo "Create it (one or multiple OpenSSH public keys), or set SSH_TOOL_SUPPORT_PUB to a file path."
  exit 1
fi

export SSH_TOOL_SUPPORT_PUB="${SUPPORT_PUB}"
"${ROOT_DIR}/scripts/build-zips.sh"
"${ROOT_DIR}/scripts/build-mac-dmg.sh"
"${ROOT_DIR}/scripts/build-win-exe.sh"

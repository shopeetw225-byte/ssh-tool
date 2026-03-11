#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WIN_PKG="${ROOT_DIR}/packages/ssh-tool-win"
DIST_DIR="${ROOT_DIR}/dist"
ARCH="${SSH_TOOL_WIN_ARCH:-amd64}"
ARCH_SUFFIX=""
if [[ "${ARCH}" != "amd64" ]]; then
  ARCH_SUFFIX="-${ARCH}"
fi
OUT="${DIST_DIR}/ssh-tool-win${ARCH_SUFFIX}.exe"

SUPPORT_PUB="${SSH_TOOL_SUPPORT_PUB:-${ROOT_DIR}/keys/support.pub}"
if [[ ! -f "${SUPPORT_PUB}" ]]; then
  SUPPORT_PUB="${WIN_PKG}/support.pub"
fi

if [[ ! -f "${SUPPORT_PUB}" ]]; then
  echo "Missing support.pub: ${SUPPORT_PUB}"
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "go not found. Install Go to build the Windows exe."
  exit 1
fi

mkdir -p "${DIST_DIR}"

stage="$(mktemp -d)"
trap 'rm -rf "${stage}"' EXIT

cp -f "${WIN_PKG}/ssh-tool-win.go" "${stage}/ssh-tool-win.go"
cp -f "${WIN_PKG}/remote-support.ps1" "${stage}/remote-support.ps1"
cp -f "${WIN_PKG}/bore.exe" "${stage}/bore.exe"
cp -f "${SUPPORT_PUB}" "${stage}/support.pub"
mkdir -p "${stage}/public"
cp -f "${WIN_PKG}/public/remote-support-ui.html" "${stage}/public/remote-support-ui.html"

GOOS=windows GOARCH="${ARCH}" CGO_ENABLED=0 \
  go build -trimpath -ldflags "-s -w" -o "${OUT}" "${stage}/ssh-tool-win.go"

echo "Wrote ${OUT}"

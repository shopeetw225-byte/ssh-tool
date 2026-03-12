#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
BUILD_DIR="${ROOT_DIR}/build"
WIN_PKG="${ROOT_DIR}/packages/ssh-tool-win"

ZIP_NAME="ssh-tool-win-offline"
OUT_ZIP="${DIST_DIR}/${ZIP_NAME}.zip"

OPENSSH_URL_DEFAULT="https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

select_support_pub() {
  if [[ -n "${SSH_TOOL_SUPPORT_PUB:-}" && -f "${SSH_TOOL_SUPPORT_PUB}" ]]; then
    printf '%s' "${SSH_TOOL_SUPPORT_PUB}"
    return 0
  fi
  if [[ -f "${WIN_PKG}/support.pub" ]]; then
    printf '%s' "${WIN_PKG}/support.pub"
    return 0
  fi
  printf '%s' "${WIN_PKG}/support.pub.example"
}

resolve_openssh_zip() {
  if [[ -n "${SSH_TOOL_OPENSSH_ZIP:-}" && -f "${SSH_TOOL_OPENSSH_ZIP}" ]]; then
    printf '%s' "${SSH_TOOL_OPENSSH_ZIP}"
    return 0
  fi

  local cached="${BUILD_DIR}/OpenSSH-Win64.zip"
  if [[ -f "${cached}" ]]; then
    printf '%s' "${cached}"
    return 0
  fi

  need_cmd curl

  mkdir -p "${BUILD_DIR}"
  local url="${SSH_TOOL_OPENSSH_ZIP_URL:-${OPENSSH_URL_DEFAULT}}"
  echo "[*] Downloading OpenSSH-Win64.zip for offline bundle..." >&2
  echo "    ${url}" >&2
  curl -fSL --retry 2 --connect-timeout 15 -o "${cached}" "${url}" >&2
  if [[ ! -f "${cached}" ]]; then
    return 1
  fi
  printf '%s' "${cached}"
}

main() {
  need_cmd zip

  mkdir -p "${DIST_DIR}"
  rm -f "${OUT_ZIP}"

  # Build both Windows exes so the offline bundle works for either arch.
  "${ROOT_DIR}/scripts/build-win-exe.sh"
  SSH_TOOL_WIN_ARCH=arm64 "${ROOT_DIR}/scripts/build-win-exe.sh"

  local openssh_zip
  openssh_zip="$(resolve_openssh_zip)" || true
  if [[ -z "${openssh_zip}" || ! -f "${openssh_zip}" ]]; then
    echo "[x] Failed to prepare OpenSSH-Win64.zip for offline bundle." >&2
    echo "    - Set SSH_TOOL_OPENSSH_ZIP to a local zip file, or" >&2
    echo "    - Allow network access so the script can download it." >&2
    exit 1
  fi

  local support_pub
  support_pub="$(select_support_pub)"

  local stage
  stage="$(mktemp -d)"
  trap "rm -rf \"${stage}\"" EXIT

  mkdir -p "${stage}/${ZIP_NAME}"
  cp -f "${DIST_DIR}/ssh-tool-win.exe" "${stage}/${ZIP_NAME}/ssh-tool-win.exe"
  cp -f "${DIST_DIR}/ssh-tool-win-arm64.exe" "${stage}/${ZIP_NAME}/ssh-tool-win-arm64.exe"
  cp -f "${openssh_zip}" "${stage}/${ZIP_NAME}/OpenSSH-Win64.zip"
  cp -f "${support_pub}" "${stage}/${ZIP_NAME}/support.pub"

  cat >"${stage}/${ZIP_NAME}/README.txt" <<'EOF'
SSH Tool (Windows) — Offline Bundle

This zip includes everything needed for machines where Windows Update/Optional Features are blocked.

How to use:
1) Extract this zip to a folder (keep files together)
2) Run:
   - ssh-tool-win.exe        (most PCs, x64)
   - ssh-tool-win-arm64.exe  (Windows on ARM64)
3) Approve UAC -> a local web page will open -> click Start/Stop

Files:
- OpenSSH-Win64.zip is used only if the PC does not have OpenSSH Server installed and it cannot be installed via Add-WindowsCapability.
EOF

  (cd "${stage}" && zip -qr "${OUT_ZIP}" "${ZIP_NAME}")
  echo "Wrote ${OUT_ZIP}"
}

main "$@"

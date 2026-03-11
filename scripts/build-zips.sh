#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"

rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

if ! command -v zip >/dev/null 2>&1; then
  echo "zip not found. Install zip or create archives manually."
  exit 1
fi

stage_and_zip() {
  local name="$1"
  local out="${DIST_DIR}/${name}.zip"
  local stage
  stage="$(mktemp -d)"
  trap 'rm -rf "${stage}"' RETURN

  mkdir -p "${stage}/${name}"
  shift
  while [[ $# -gt 0 ]]; do
    local src="$1"
    local dst_rel="$2"
    shift 2
    mkdir -p "$(dirname -- "${stage}/${name}/${dst_rel}")"
    cp -f "${src}" "${stage}/${name}/${dst_rel}"
  done

  # Preserve executable bits for macOS entrypoints.
  if [[ -d "${stage}/${name}" ]]; then
    find "${stage}/${name}" -maxdepth 1 -type f \( -name "*.sh" -o -name "*.command" -o -name "bore" -o -name "bore-*" \) -exec chmod +x {} \; 2>/dev/null || true
  fi

  (cd "${stage}" && zip -qr "${out}" "${name}")
  echo "Wrote ${out}"
}

select_support_pub() {
  local pkg_dir="$1"
  if [[ -n "${SSH_TOOL_SUPPORT_PUB:-}" && -f "${SSH_TOOL_SUPPORT_PUB}" ]]; then
    printf '%s' "${SSH_TOOL_SUPPORT_PUB}"
    return 0
  fi
  if [[ -f "${pkg_dir}/support.pub" ]]; then
    printf '%s' "${pkg_dir}/support.pub"
    return 0
  fi
  printf '%s' "${pkg_dir}/support.pub.example"
}

stage_and_zip "ssh-tool-win" \
  "${ROOT_DIR}/packages/ssh-tool-win/remote-support.bat" "remote-support.bat" \
  "${ROOT_DIR}/packages/ssh-tool-win/remote-support-stop.bat" "remote-support-stop.bat" \
  "${ROOT_DIR}/packages/ssh-tool-win/remote-support.ps1" "remote-support.ps1" \
  "${ROOT_DIR}/packages/ssh-tool-win/bore.exe" "bore.exe" \
  "$(select_support_pub "${ROOT_DIR}/packages/ssh-tool-win")" "support.pub"

stage_and_zip "ssh-tool-mac" \
  "${ROOT_DIR}/packages/ssh-tool-mac/remote-support.command" "remote-support.command" \
  "${ROOT_DIR}/packages/ssh-tool-mac/remote-support-stop.command" "remote-support-stop.command" \
  "${ROOT_DIR}/packages/ssh-tool-mac/remote-support.sh" "remote-support.sh" \
  "${ROOT_DIR}/packages/ssh-tool-mac/bore" "bore" \
  "${ROOT_DIR}/packages/ssh-tool-mac/bore-arm64" "bore-arm64" \
  "${ROOT_DIR}/packages/ssh-tool-mac/bore-x86_64" "bore-x86_64" \
  "$(select_support_pub "${ROOT_DIR}/packages/ssh-tool-mac")" "support.pub"

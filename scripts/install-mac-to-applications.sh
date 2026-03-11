#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

DMG_PATH="${1:-${ROOT_DIR}/dist/ssh-tool-mac.dmg}"
APP_DST="/Applications/SSH Tool.app"

if [[ ! -f "${DMG_PATH}" ]]; then
  echo "DMG not found: ${DMG_PATH}" >&2
  exit 1
fi

if [[ -e "${APP_DST}" ]]; then
  echo "Already installed: ${APP_DST}" >&2
  echo "Remove it first, then rerun this installer." >&2
  exit 1
fi

MNT="$(mktemp -d /tmp/ssh-tool-mac-install.XXXXXX)"
cleanup() {
  hdiutil detach "${MNT}" >/dev/null 2>&1 || true
  rmdir "${MNT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

hdiutil attach -nobrowse -readonly -mountpoint "${MNT}" "${DMG_PATH}" >/dev/null

if [[ ! -d "${MNT}/SSH Tool.app" ]]; then
  echo "App bundle not found in DMG: ${MNT}/SSH Tool.app" >&2
  exit 1
fi

ditto "${MNT}/SSH Tool.app" "${APP_DST}"
xattr -dr com.apple.quarantine "${APP_DST}" >/dev/null 2>&1 || true

echo "Installed: ${APP_DST}"


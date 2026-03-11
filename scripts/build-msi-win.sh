#!/usr/bin/env bash
# scripts/build-msi-win.sh
# ─────────────────────────────────────────────────────────────────────────────
# Build a Windows MSI installer for ssh-tool-win.
#
# Toolchain priority (auto-detected):
#   1. WiX v4 CLI  — `wix`   (dotnet global tool:  dotnet tool install -g wix)
#   2. WiX v3/wixl — `wixl`  (brew install msitools)
#
# Requirements (install ONE of the above):
#   Option A – WiX v4:
#     brew install --cask dotnet-sdk
#     dotnet tool install --global wix
#   Option B – msitools:
#     brew install msitools   (may need: brew install svn first)
#
# Usage:
#   ./scripts/build-msi-win.sh
#   SSH_TOOL_SUPPORT_PUB=/keys/support.pub  ./scripts/build-msi-win.sh
#
# Output: dist/ssh-tool-win.msi
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
WIN_PKG="${ROOT_DIR}/packages/ssh-tool-win"
DIST_DIR="${ROOT_DIR}/dist"
BUILD_DIR="${ROOT_DIR}/build"
WXS_V4_TEMPLATE="${BUILD_DIR}/ssh-tool-win-v4.wxs"
WXS_V3_TEMPLATE="${BUILD_DIR}/ssh-tool-win.wxs"
WXS_FINAL="${BUILD_DIR}/ssh-tool-win-final.wxs"
MSI_OUT="${DIST_DIR}/ssh-tool-win.msi"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { printf '\e[32m[*]\e[0m %s\n' "$*"; }
warn()  { printf '\e[33m[!]\e[0m %s\n' "$*"; }
error() { printf '\e[31m[x]\e[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

# ── Detect WiX toolchain ──────────────────────────────────────────────────────
detect_toolchain() {
  # Prefer WiX v4 (dotnet global tool)
  if command -v wix >/dev/null 2>&1; then
    WIX_TOOL="wix4"
    info "Toolchain: WiX v4  ($(wix --version 2>&1 | head -1))"
    return
  fi

  # Also look in ~/.dotnet/tools (common install path for dotnet global tools)
  local dotnet_tools="${HOME}/.dotnet/tools/wix"
  if [[ -x "${dotnet_tools}" ]]; then
    WIX_TOOL="wix4"
    WIX_BIN="${dotnet_tools}"
    info "Toolchain: WiX v4  (${dotnet_tools})"
    return
  fi

  # Fall back to wixl (msitools)
  if command -v wixl >/dev/null 2>&1; then
    WIX_TOOL="wixl"
    info "Toolchain: wixl  ($(wixl --version 2>&1 | head -1))"
    return
  fi

  # Try to install WiX v4 via dotnet
  if command -v dotnet >/dev/null 2>&1; then
    warn "WiX not found. Installing via dotnet tool install --global wix ..."
    dotnet tool install --global wix 2>&1 | sed 's/^/  /'
    export PATH="${HOME}/.dotnet/tools:${PATH}"
    if command -v wix >/dev/null 2>&1; then
      WIX_TOOL="wix4"
      info "Toolchain: WiX v4 (newly installed)"
      return
    fi
  fi

  # Try to install msitools
  if command -v brew >/dev/null 2>&1; then
    warn "wixl not found. Trying: brew install msitools ..."
    brew install msitools 2>&1 | tail -5
    if command -v wixl >/dev/null 2>&1; then
      WIX_TOOL="wixl"
      info "Toolchain: wixl (newly installed)"
      return
    fi
  fi

  die "No WiX toolchain found. Install one of:
  Option A (recommended):
    brew install --cask dotnet-sdk
    dotnet tool install --global wix
  Option B:
    brew install msitools   (requires: brew install svn)"
}

WIX_TOOL=""
WIX_BIN=""   # optional override path

# ── Resolve support.pub ───────────────────────────────────────────────────────
resolve_support_pub() {
  if [[ -n "${SSH_TOOL_SUPPORT_PUB:-}" && -f "${SSH_TOOL_SUPPORT_PUB}" ]]; then
    printf '%s' "${SSH_TOOL_SUPPORT_PUB}"
    return 0
  fi
  local real="${WIN_PKG}/support.pub"
  if [[ -f "${real}" ]]; then
    printf '%s' "${real}"
    return 0
  fi
  printf '%s' "${WIN_PKG}/support.pub.example"
}

# ── Verify required source files ──────────────────────────────────────────────
verify_sources() {
  local missing=0
  for f in \
    "${WIN_PKG}/remote-support.ps1" \
    "${WIN_PKG}/remote-support.bat" \
    "${WIN_PKG}/remote-support-stop.bat" \
    "${WIN_PKG}/bore.exe"; do
    if [[ ! -f "${f}" ]]; then
      error "Missing required file: ${f}"
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] || die "One or more required source files are missing."
}

# ── Generate final .wxs from the appropriate template ────────────────────────
generate_wxs() {
  local support_pub="$1"
  local template

  if [[ "${WIX_TOOL}" == "wix4" ]]; then
    template="${WXS_V4_TEMPLATE}"
    info "Using WiX v4 template: ${template}"
  else
    template="${WXS_V3_TEMPLATE}"
    info "Using WiX v3 template: ${template}"
  fi

  cp -f "${template}" "${WXS_FINAL}"

  # Substitute source directory path (use forward slashes for cross-platform compat)
  local src_dir="${WIN_PKG}"

  sed -i.bak "s|SRCDIR_PLACEHOLDER|${src_dir}|g" "${WXS_FINAL}"
  sed -i.bak "s|SUPPORT_PUB_PLACEHOLDER|${support_pub}|g" "${WXS_FINAL}"
  rm -f "${WXS_FINAL}.bak"

  info "Generated:  ${WXS_FINAL}"
  info "Source dir: ${src_dir}"
  info "support.pub: ${support_pub}"
}

# ── Build MSI ─────────────────────────────────────────────────────────────────
build_msi() {
  mkdir -p "${DIST_DIR}"
  rm -f "${MSI_OUT}"

  if [[ "${WIX_TOOL}" == "wix4" ]]; then
    # WiX v4 CLI
    local wix_cmd
    if [[ -n "${WIX_BIN}" ]]; then
      wix_cmd="${WIX_BIN}"
    else
      wix_cmd="wix"
    fi

    info "Running: ${wix_cmd} build ..."
    "${wix_cmd}" build \
      "${WXS_FINAL}" \
      -arch x64 \
      -out "${MSI_OUT}" \
      2>&1 | sed 's/^/  /'

  else
    # WiX v3 / wixl
    info "Running: wixl ..."
    wixl \
      -a x64 \
      -o "${MSI_OUT}" \
      "${WXS_FINAL}" \
      2>&1 | sed 's/^/  /'
  fi

  if [[ ! -f "${MSI_OUT}" ]]; then
    die "Build finished but MSI was not created: ${MSI_OUT}"
  fi

  local size
  size="$(du -sh "${MSI_OUT}" | awk '{print $1}')"
  info "✓ MSI built: ${MSI_OUT}  (${size})"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  info "══════════════════════════════════════════"
  info "  SSH Tool Win — MSI Build"
  info "══════════════════════════════════════════"

  verify_sources
  detect_toolchain

  local support_pub
  support_pub="$(resolve_support_pub)"

  mkdir -p "${BUILD_DIR}" "${DIST_DIR}"
  generate_wxs "${support_pub}"
  build_msi

  info "══════════════════════════════════════════"
  info "  Output: ${MSI_OUT}"
  info "══════════════════════════════════════════"
}

main "$@"

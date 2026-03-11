#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
PKG_DIR="${ROOT_DIR}/packages/ssh-tool-mac"

NAME="ssh-tool-mac"
VOLNAME="ssh-tool-mac"
DMG_OUT="${DIST_DIR}/${NAME}.dmg"
APP_NAME="SSH Tool"
APP_BUNDLE_NAME="${APP_NAME}.app"
APP_BUNDLE_ID="com.openclaw.ssh-tool"
APP_EXECUTABLE_NAME="ssh-tool"
APP_VERSION="1.0.0"
APP_URL_SCHEME="ssh-tool"

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Missing required file: $path" >&2
    exit 1
  fi
}

select_support_pub() {
  if [[ -n "${SSH_TOOL_SUPPORT_PUB:-}" && -f "${SSH_TOOL_SUPPORT_PUB}" ]]; then
    printf '%s' "${SSH_TOOL_SUPPORT_PUB}"
    return 0
  fi
  if [[ -f "${PKG_DIR}/support.pub" ]]; then
    printf '%s' "${PKG_DIR}/support.pub"
    return 0
  fi
  printf '%s' "${PKG_DIR}/support.pub.example"
}

build_app_bundle() {
  local out_dir="$1"
  local support_pub="$2"

  local app_bundle="${out_dir}/${APP_BUNDLE_NAME}"
  local swift_src="${PKG_DIR}/launcher/main.swift"
  local control_html="${PKG_DIR}/control.html"

  require_file "${swift_src}"
  require_file "${control_html}"

  local contents_dir="${app_bundle}/Contents"
  local macos_dir="${contents_dir}/MacOS"
  local res_dir="${contents_dir}/Resources/ssh-tool-mac"
  mkdir -p "${macos_dir}" "${res_dir}"

  cat >"${contents_dir}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${APP_EXECUTABLE_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${APP_BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.15</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>${APP_BUNDLE_ID}</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>${APP_URL_SCHEME}</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
EOF

  printf 'APPL????' >"${contents_dir}/PkgInfo"

  cp -f "${PKG_DIR}/remote-support.command" "${res_dir}/remote-support.command"
  cp -f "${PKG_DIR}/remote-support-stop.command" "${res_dir}/remote-support-stop.command"
  cp -f "${PKG_DIR}/remote-support.sh" "${res_dir}/remote-support.sh"
  cp -f "${PKG_DIR}/bore" "${res_dir}/bore"
  cp -f "${PKG_DIR}/bore-arm64" "${res_dir}/bore-arm64"
  cp -f "${PKG_DIR}/bore-x86_64" "${res_dir}/bore-x86_64"
  cp -f "${control_html}" "${res_dir}/control.html"
  cp -f "${support_pub}" "${res_dir}/support.pub"

  chmod +x \
    "${res_dir}/remote-support.command" \
    "${res_dir}/remote-support-stop.command" \
    "${res_dir}/remote-support.sh" \
    "${res_dir}/bore" \
    "${res_dir}/bore-arm64" \
    "${res_dir}/bore-x86_64" 2>/dev/null || true

  local sdk=""
  if [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk" ]]; then
    sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
  else
    sdk="$(xcrun --show-sdk-path)"
  fi

  local tmp_arm tmp_x86
  tmp_arm="$(mktemp -t ssh-tool.arm64.XXXXXX)"
  tmp_x86="$(mktemp -t ssh-tool.x86_64.XXXXXX)"

  swiftc -O -sdk "${sdk}" -target arm64-apple-macos11.0 -framework AppKit -framework Carbon -o "${tmp_arm}" "${swift_src}"
  swiftc -O -sdk "${sdk}" -target x86_64-apple-macos10.15 -framework AppKit -framework Carbon -o "${tmp_x86}" "${swift_src}"
  lipo -create -output "${macos_dir}/${APP_EXECUTABLE_NAME}" "${tmp_arm}" "${tmp_x86}"
  rm -f "${tmp_arm}" "${tmp_x86}" >/dev/null 2>&1 || true

  chmod +x "${macos_dir}/${APP_EXECUTABLE_NAME}" 2>/dev/null || true

  echo "${app_bundle}"
}

main() {
  if ! command -v hdiutil >/dev/null 2>&1; then
    echo "hdiutil not found (macOS required to build DMG)." >&2
    exit 1
  fi

  mkdir -p "${DIST_DIR}"
  rm -f "${DMG_OUT}"

  local support_pub
  support_pub="$(select_support_pub)"

  require_file "${PKG_DIR}/remote-support.sh"
  require_file "${PKG_DIR}/remote-support.command"
  require_file "${PKG_DIR}/remote-support-stop.command"
  require_file "${PKG_DIR}/bore"
  require_file "${PKG_DIR}/bore-arm64"
  require_file "${PKG_DIR}/bore-x86_64"
  require_file "${support_pub}"

  local stage
  stage="$(mktemp -d)"
  trap "rm -rf \"${stage}\"" EXIT

  local src="${stage}/src"
  mkdir -p "${src}"

  build_app_bundle "${src}" "${support_pub}" >/dev/null
  ln -s /Applications "${src}/Applications"

  hdiutil create \
    -volname "${VOLNAME}" \
    -srcfolder "${src}" \
    -ov \
    -format UDZO \
    "${DMG_OUT}" >/dev/null

  echo "Wrote ${DMG_OUT}"
}

main "$@"

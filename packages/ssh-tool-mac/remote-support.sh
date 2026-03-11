#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-start}"
shift || true

MINUTES="${SSH_TOOL_MINUTES:-60}"
RELAY="${SSH_TOOL_RELAY:-bore.pub}"
LOCAL_PORT="${SSH_TOOL_LOCAL_PORT:-22}"
ALLOW_LAN="${SSH_TOOL_ALLOW_LAN:-0}"
BORE_VERSION="${SSH_TOOL_BORE_VERSION:-0.6.0}"
AUTH_MODE="${SSH_TOOL_AUTH_MODE:-auto}"

case "$AUTH_MODE" in
  auto|key|password) ;;
  *) AUTH_MODE="auto" ;;
esac

if ! [[ "$MINUTES" =~ ^[0-9]+$ ]]; then MINUTES="60"; fi
if ((MINUTES < 1)); then MINUTES="60"; fi
if ((MINUTES > 1440)); then MINUTES="1440"; fi
if ! [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]]; then LOCAL_PORT="22"; fi
if ((LOCAL_PORT < 1)); then LOCAL_PORT="22"; fi
if ((LOCAL_PORT > 65535)); then LOCAL_PORT="22"; fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELF_PATH="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"
DEFAULT_KEY_CANDIDATE="${SCRIPT_DIR}/support.pub"
DEFAULT_KEY_CANDIDATE2="${SCRIPT_DIR}/support.pub.example"
SUPPORT_KEY_PATH="${SSH_TOOL_SUPPORT_KEY_PATH:-}"

STATE_DIR="${SSH_TOOL_STATE_DIR:-/var/tmp/ssh-tool}"
STATE_PATH="${SSH_TOOL_STATE_PATH:-${STATE_DIR}/active-session.json}"
PERSISTED_SELF_PATH="${STATE_DIR}/remote-support.sh"

msg() { printf '%s\n' "[*] $*"; }
warn() { printf '%s\n' "[!] $*" >&2; }
err() { printf '%s\n' "[x] $*" >&2; }

sshd_config_has_markers() {
  local p="${1:-/etc/ssh/sshd_config}"
  [[ -f "$p" ]] || return 1
  grep -qE '^# ssh-tool session [0-9a-f]{16,} BEGIN$' "$p" 2>/dev/null
}

sshd_config_last_marker_session_id() {
  local p="${1:-/etc/ssh/sshd_config}"
  [[ -f "$p" ]] || return 1
  sed -nE 's/^# ssh-tool session ([0-9a-f]{16,}) BEGIN$/\1/p' "$p" | tail -n 1
}

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    return 0
  fi
  return 1
}

relaunch_sudo() {
  msg "Requesting sudo..."
  exec sudo -E "$SELF_PATH" "${ACTION}" "$@"
}

ensure_dir() {
  mkdir -p "$1"
}

persist_self_for_cleanup() {
  [[ "$(id -u)" -eq 0 ]] || return 0
  ensure_dir "$STATE_DIR"
  if [[ "$SELF_PATH" != "$PERSISTED_SELF_PATH" ]]; then
    cp -f "$SELF_PATH" "$PERSISTED_SELF_PATH" >/dev/null 2>&1 || return 0
    chmod +x "$PERSISTED_SELF_PATH" >/dev/null 2>&1 || true
    chown root:wheel "$PERSISTED_SELF_PATH" >/dev/null 2>&1 || true
  fi
  SELF_PATH="$PERSISTED_SELF_PATH"
}

try_read_support_keys() {
  local p="$1"
  [[ -z "$p" || ! -f "$p" ]] && return 0
  grep -v '^[[:space:]]*#' "$p" | sed '/^[[:space:]]*$/d' || true
}

read_support_keys_strict() {
  local p="$1"
  if [[ -z "$p" || ! -f "$p" ]]; then
    err "Support key file not found: $p"
    exit 1
  fi
  local lines
  lines="$(try_read_support_keys "$p")"
  if [[ -z "$lines" ]]; then
    err "Support key file is empty: $p"
    exit 1
  fi
  printf '%s\n' "$lines"
}

ensure_bore_available() {
  if [[ -x "${SCRIPT_DIR}/bore" ]]; then return 0; fi
  if [[ -x "${STATE_DIR}/bore" ]]; then return 0; fi
  if command -v bore >/dev/null 2>&1; then return 0; fi

  msg "bore not found; downloading bore v${BORE_VERSION}..."
  download_bore >/dev/null
  if [[ -x "${STATE_DIR}/bore" ]]; then return 0; fi
  err "Failed to download bore. You can also install it with: brew install bore-cli"
  exit 1
}

download_bore() {
  ensure_dir "$STATE_DIR"
  local arch url tmp_dir tmp_tar out
  arch="$(uname -m)"
  case "$arch" in
    arm64) url="https://github.com/ekzhang/bore/releases/download/v${BORE_VERSION}/bore-v${BORE_VERSION}-aarch64-apple-darwin.tar.gz" ;;
    x86_64) url="https://github.com/ekzhang/bore/releases/download/v${BORE_VERSION}/bore-v${BORE_VERSION}-x86_64-apple-darwin.tar.gz" ;;
    *)
      err "Unsupported macOS arch: ${arch}"
      exit 1
      ;;
  esac

  tmp_dir="$(mktemp -d "${STATE_DIR}/bore.dl.XXXXXX")"
  tmp_tar="${tmp_dir}/bore.tar.gz"
  out="${STATE_DIR}/bore"

  if ! curl -fSL --retry 2 --connect-timeout 10 -o "$tmp_tar" "$url" >/dev/null 2>&1; then
    rm -rf "$tmp_dir" >/dev/null 2>&1 || true
    err "Download failed: ${url}"
    exit 1
  fi

  if tar -xzf "$tmp_tar" -C "$tmp_dir" bore >/dev/null 2>&1; then
    :
  else
    tar -xzf "$tmp_tar" -C "$tmp_dir" >/dev/null 2>&1 || true
    local found
    found="$(find "$tmp_dir" -name bore -type f 2>/dev/null | head -n 1 || true)"
    if [[ -z "$found" ]]; then
      rm -rf "$tmp_dir" >/dev/null 2>&1 || true
      err "Failed to extract bore binary."
      exit 1
    fi
    cp -f "$found" "${tmp_dir}/bore"
  fi

  cp -f "${tmp_dir}/bore" "$out"
  chmod +x "$out"
  rm -rf "$tmp_dir" >/dev/null 2>&1 || true
  echo "$out"
}

relay_host_only() {
  local r="$1"
  if [[ "$r" == *:* ]]; then
    printf '%s' "${r%%:*}"
  else
    printf '%s' "$r"
  fi
}

get_target_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s' "$SUDO_USER"
    return 0
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    local u
    u="$(stat -f%Su /dev/console 2>/dev/null || true)"
    if [[ -n "$u" && "$u" != "root" ]]; then
      printf '%s' "$u"
      return 0
    fi
  fi

  printf '%s' "$(id -un)"
}

get_user_home() {
  local u="$1"
  local home
  home="$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
  if [[ -z "$home" ]]; then
    home="$(eval echo "~$u" 2>/dev/null || true)"
  fi
  if [[ -z "$home" || ! -d "$home" ]]; then
    err "Failed to resolve home directory for user: $u"
    exit 1
  fi
  printf '%s' "$home"
}

backup_file() {
  local src="$1"
  local dst="$2"
  if [[ -f "$src" ]]; then
    cp -f "$src" "$dst"
    return 0
  fi
  return 1
}

generate_password() {
  # Use subshell to avoid pipefail on SIGPIPE.
  (set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
}

generate_suffix() {
  (set +o pipefail; LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 4)
}

create_temp_user() {
  local max_retries=5
  local attempt=0
  local temp_pass temp_user
  temp_pass="$(generate_password)"

  while [[ $attempt -lt $max_retries ]]; do
    temp_user="support_$(generate_suffix)"
    if dscl . -read "/Users/${temp_user}" >/dev/null 2>&1; then
      attempt=$((attempt + 1))
      continue
    fi

    local uid=550
    while dscl . -list /Users UniqueID 2>/dev/null | awk '{print $2}' | grep -q "^${uid}$"; do
      uid=$((uid + 1))
    done

    sudo dscl . -create "/Users/${temp_user}" >/dev/null 2>&1
    sudo dscl . -create "/Users/${temp_user}" UserShell /bin/bash >/dev/null 2>&1
    sudo dscl . -create "/Users/${temp_user}" RealName "Remote Support" >/dev/null 2>&1
    sudo dscl . -create "/Users/${temp_user}" UniqueID "$uid" >/dev/null 2>&1
    sudo dscl . -create "/Users/${temp_user}" PrimaryGroupID 20 >/dev/null 2>&1
    sudo dscl . -create "/Users/${temp_user}" NFSHomeDirectory "/Users/${temp_user}" >/dev/null 2>&1
    sudo dscl . -passwd "/Users/${temp_user}" "$temp_pass" >/dev/null 2>&1
    sudo createhomedir -c -u "$temp_user" >/dev/null 2>&1 || true

    sudo dseditgroup -o edit -a "$temp_user" -t user com.apple.access_ssh >/dev/null 2>&1 || true

    printf '%s:%s' "$temp_user" "$temp_pass"
    return 0
  done

  return 1
}

delete_temp_user() {
  local u="$1"
  [[ -z "$u" ]] && return 0
  if dscl . -read "/Users/${u}" >/dev/null 2>&1; then
    sudo sysadminctl -deleteUser "$u" >/dev/null 2>&1 || sudo dscl . -delete "/Users/${u}" >/dev/null 2>&1 || true
  fi
  return 0
}

append_marker_block() {
  local path="$1"
  local session_id="$2"
  shift 2
  {
    printf '\n'
    printf '# ssh-tool session %s BEGIN\n' "$session_id"
    for line in "$@"; do
      printf '%s\n' "$line"
    done
    printf '# ssh-tool session %s END\n' "$session_id"
  } >>"$path"
}

remove_marker_block() {
  local path="$1"
  local session_id="$2"
  [[ -f "$path" ]] || return 0
  local tmp
  tmp="$(mktemp -t ssh-tool.recover.XXXXXX)"
  awk -v sid="$session_id" '
    $0 == "# ssh-tool session " sid " BEGIN" {skip=1; next}
    $0 == "# ssh-tool session " sid " END" {skip=0; next}
    skip != 1 {print}
  ' "$path" >"$tmp"
  cat "$tmp" >"$path"
  rm -f "$tmp" >/dev/null 2>&1 || true
}

copy_to_clipboard() {
  if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$1" | pbcopy
  fi
}

remote_login_state() {
  /usr/sbin/systemsetup -getremotelogin 2>/dev/null || true
}

remote_login_enabled_fallback() {
  # launchctl print returns 0 if the service is loaded into the system domain.
  if /bin/launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
    return 0
  fi

  # Fallback to port listener check (best-effort).
  if lsof -nP -iTCP:"${LOCAL_PORT}" -sTCP:LISTEN 2>/dev/null | grep -E "TCP .*:${LOCAL_PORT} \\(LISTEN\\)" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

remote_login_enabled() {
  local s=""
  s="$(remote_login_state)"
  if [[ -n "$s" ]]; then
    printf '%s' "$s" | grep -qi "Remote Login: On" && return 0
    printf '%s' "$s" | grep -qi "Remote Login: Off" && return 1
  fi
  remote_login_enabled_fallback
}

set_remote_login() {
  local onoff="$1" # on/off
  local desired=0
  if [[ "$onoff" == "on" ]]; then desired=1; fi

  # If already in desired state, no-op.
  if ((desired == 1)); then
    remote_login_enabled_fallback && return 0
  else
    remote_login_enabled_fallback || return 0
  fi

  local out=""
  # systemsetup may fail due to Full Disk Access requirements; do best-effort and check state afterwards.
  out="$(/usr/sbin/systemsetup -setremotelogin "$onoff" 2>&1 <<<"yes" || true)"

  if ((desired == 1)); then
    remote_login_enabled_fallback && return 0
  else
    remote_login_enabled_fallback || return 0
  fi

  local plist="/System/Library/LaunchDaemons/ssh.plist"
  local launchctl_log=""
  run_launchctl() {
    local name="$1"
    shift
    local out2=""
    out2="$("$@" 2>&1 || true)"
    if [[ -n "$out2" ]]; then
      launchctl_log+=$'\n'"$name: $*"$'\n'"$out2"$'\n'
    else
      launchctl_log+=$'\n'"$name: $*"$'\n'
    fi
  }

  if [[ "$desired" == "1" ]]; then
    warn "systemsetup failed; enabling Remote Login via launchctl..."
    run_launchctl "enable" /bin/launchctl enable system/com.openssh.sshd
    run_launchctl "bootstrap" /bin/launchctl bootstrap system "$plist"
    run_launchctl "enable" /bin/launchctl enable system/com.openssh.sshd
    run_launchctl "kickstart" /bin/launchctl kickstart -k system/com.openssh.sshd

    local deadline=$((SECONDS + 15))
    while ((SECONDS < deadline)); do
      if remote_login_enabled_fallback; then
        return 0
      fi
      sleep 0.5
    done

    # Last resort: legacy load -w tends to work across macOS versions.
    run_launchctl "load-w" /bin/launchctl load -w "$plist"

    deadline=$((SECONDS + 15))
    while ((SECONDS < deadline)); do
      if remote_login_enabled_fallback; then
        return 0
      fi
      sleep 0.5
    done

    err "Failed to enable Remote Login."
    if [[ -n "$out" ]]; then
      printf '%s\n' "$out" >&2
    fi
    if [[ -n "$launchctl_log" ]]; then
      printf '%s\n' "$launchctl_log" >&2
    fi
    return 1
  fi

  warn "systemsetup failed; disabling Remote Login via launchctl..."
  run_launchctl "disable" /bin/launchctl disable system/com.openssh.sshd
  run_launchctl "bootout" /bin/launchctl bootout system "$plist"
  run_launchctl "unload-w" /bin/launchctl unload -w "$plist"
  return 0
}

restart_sshd() {
  if command -v launchctl >/dev/null 2>&1; then
    /bin/launchctl kickstart -k system/com.openssh.sshd >/dev/null 2>&1 || true
  fi
}

host_keys_present() {
  compgen -G "/etc/ssh/ssh_host_*_key" >/dev/null 2>&1
}

ensure_host_keys() {
  if host_keys_present; then
    return 0
  fi

  msg "No SSH host keys found; generating..."
  if [[ -x "/usr/libexec/sshd-keygen-wrapper" ]]; then
    /usr/libexec/sshd-keygen-wrapper >/dev/null 2>&1 || true
  fi
  if ! host_keys_present; then
    if command -v ssh-keygen >/dev/null 2>&1; then
      ssh-keygen -A >/dev/null 2>&1 || true
    fi
  fi

  if host_keys_present; then
    return 0
  fi

  err "sshd host keys are missing. Expected /etc/ssh/ssh_host_*_key."
  err "Try: sudo /usr/libexec/sshd-keygen-wrapper  (or: sudo ssh-keygen -A)"
  exit 1
}

start_bore() {
  local out="$1"
  local errf="$2"
  local bore_bin
  ensure_bore_available
  if [[ -x "${SCRIPT_DIR}/bore" ]]; then bore_bin="${SCRIPT_DIR}/bore"
  elif [[ -x "${STATE_DIR}/bore" ]]; then bore_bin="${STATE_DIR}/bore"
  else bore_bin="$(command -v bore || true)"; fi

  nohup "$bore_bin" local "$LOCAL_PORT" --to "$RELAY" >"$out" 2>"$errf" &
  echo $! # pid
}

wait_bore_port() {
  local relay_host="$1"
  local out="$2"
  local errf="$3"
  local deadline
  deadline=$((SECONDS + 25))
  while ((SECONDS < deadline)); do
    local text=""
    [[ -f "$out" ]] && text+="$(tail -n 50 "$out" 2>/dev/null || true)"
    [[ -f "$errf" ]] && text+=$'\n'"$(tail -n 50 "$errf" 2>/dev/null || true)"
    local port
    port="$(printf '%s' "$text" | sed -nE "s/.*${relay_host//./\\.}:([0-9]+).*/\\1/p" | head -n 1 || true)"
    if [[ -n "$port" ]]; then
      printf '%s' "$port"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

write_session_html() {
  local path="$1"
  local cmd="$2"
  local exp="$3"
  local note="$4"
  local user="$5"
  local pass="${6:-}"
  local pass_row=""
  if [[ -n "$pass" ]]; then
    pass_row="<div>Password</div><div><b id=\"sshPass\">${pass}</b></div>"
  fi
  cat >"$path" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Remote Support Session</title>
  <style>
    :root{--bg0:#0b1020;--bg1:#0b1b2f;--card:rgba(255,255,255,.06);--text:rgba(255,255,255,.92);--muted:rgba(255,255,255,.62);--border:rgba(255,255,255,.12);}
    *{box-sizing:border-box}
    body{margin:0;min-height:100vh;color:var(--text);font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial;background:
      radial-gradient(1000px 700px at 12% 12%, rgba(74,222,128,.12), transparent 60%),
      radial-gradient(900px 700px at 78% 28%, rgba(56,189,248,.14), transparent 55%),
      linear-gradient(160deg,var(--bg0),var(--bg1));}
    .wrap{max-width:980px;margin:0 auto;padding:28px 18px 44px}
    .card{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:16px;backdrop-filter:blur(8px)}
    h1{margin:0 0 6px 0;font-size:22px}
    .sub{color:var(--muted);font-size:13px;margin-bottom:14px}
    .code{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono","Courier New",monospace;border:1px solid var(--border);background:rgba(0,0,0,.25);border-radius:12px;padding:12px;overflow:auto;white-space:nowrap}
    .row{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-top:12px}
    .btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;border:1px solid var(--border);background:rgba(255,255,255,.08);color:var(--text);padding:9px 10px;border-radius:12px;text-decoration:none;font-size:13px;cursor:pointer;user-select:none}
    .btn:hover{background:rgba(255,255,255,.12)}
    .btn.primary{border-color:rgba(56,189,248,.35);background:rgba(56,189,248,.15)}
    .btn.danger{border-color:rgba(251,113,133,.35);background:rgba(251,113,133,.14)}
    .tip{color:var(--muted);font-size:12px;margin-top:10px}
    .kv{display:grid;grid-template-columns:140px 1fr;gap:8px 12px;margin-top:12px;color:var(--muted);font-size:13px}
    .kv b{color:var(--text);font-weight:600}
  </style>
  <script>
    async function copyById(id) {
      const el = document.getElementById(id);
      if (!el) return;
      const text = (el.textContent || "").trim();
      if (!text) return;
      try {
        await navigator.clipboard.writeText(text);
      } catch {
        // ignore
      }
    }
  </script>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>Remote Support Session</h1>
      <div class="sub">Send the command below to support. This session auto-stops at the expiry time.</div>
      <div class="code" id="sshCmd">${cmd}</div>
      <div class="row">
        <button class="btn primary" type="button" onclick="copyById('sshCmd')">Copy SSH Command</button>
        <button class="btn" type="button" onclick="copyById('sshPass')">Copy Password</button>
        <a class="btn danger" href="ssh-tool://stop" onclick="return confirm('Stop the session now?')">Stop Session</a>
        <a class="btn" href="ssh-tool://recover" onclick="return confirm('Recover (best-effort cleanup)?')">Recover</a>
      </div>
      <div class="kv">
        <div>User</div><div><b>${user}</b></div>
        ${pass_row}
        <div>Expires at</div><div><b>${exp}</b></div>
        <div>Security</div><div><b>${note}</b></div>
      </div>
      <div class="tip">Stop will open SSH Tool. Fallback: open SSH Tool again (it will stop), or run this script again with <b>stop</b>.</div>
    </div>
  </div>
</body>
</html>
EOF
}

open_session_file() {
  local path="$1"
  if [[ "${SSH_TOOL_NO_OPEN:-0}" == "1" ]]; then
    return 0
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    local u uid
    u="$(stat -f%Su /dev/console 2>/dev/null || true)"
    if [[ -n "$u" && "$u" != "root" ]]; then
      uid="$(id -u "$u" 2>/dev/null || true)"
      if [[ -n "$uid" ]]; then
        /bin/launchctl asuser "$uid" /usr/bin/open "$path" >/dev/null 2>&1 || true
        return 0
      fi
    fi
  fi

  open "$path" >/dev/null 2>&1 || true
}

start_session() {
  if need_root; then relaunch_sudo "$@"; fi

  if [[ -z "$SUPPORT_KEY_PATH" ]]; then
    if [[ -f "$DEFAULT_KEY_CANDIDATE" ]]; then
      SUPPORT_KEY_PATH="$DEFAULT_KEY_CANDIDATE"
    elif [[ -f "$DEFAULT_KEY_CANDIDATE2" ]]; then
      SUPPORT_KEY_PATH="$DEFAULT_KEY_CANDIDATE2"
    fi
  fi

  ensure_dir "$STATE_DIR"
  persist_self_for_cleanup

  # Preflight before touching ssh/sshd settings.
  ensure_bore_available

  if [[ -f "$STATE_PATH" ]]; then
    err "An active session already exists (${STATE_PATH}). Run: ${SELF_PATH} stop"
    exit 1
  fi

  local sshd_config="/etc/ssh/sshd_config"
  if [[ ! -f "$sshd_config" ]]; then
    err "sshd_config not found: $sshd_config"
    exit 1
  fi
  if sshd_config_has_markers "$sshd_config"; then
    warn "Found ssh-tool markers in ${sshd_config}, but no state file at ${STATE_PATH}."
    warn "Previous run may have been interrupted. Attempting auto-recovery..."
    if "$SELF_PATH" recover --state "$STATE_PATH"; then
      :
    else
      err "Auto-recovery failed. Run: ${SELF_PATH} recover"
      exit 1
    fi
    if sshd_config_has_markers "$sshd_config"; then
      err "Auto-recovery did not clear ssh-tool markers. Run: ${SELF_PATH} recover"
      exit 1
    fi
  fi

  ensure_host_keys

  local session_id
  session_id="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')"
  local created_at expires_at
  created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  expires_at="$(date -u -v +"${MINUTES}M" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local base_user base_home
  base_user="$(get_target_user)"
  base_home="$(get_user_home "$base_user")"

  local session_dir="${STATE_DIR}/sessions/${session_id}"
  ensure_dir "$session_dir"

  local support_keys effective_mode
  support_keys="$(try_read_support_keys "$SUPPORT_KEY_PATH")"
  effective_mode="$AUTH_MODE"
  if [[ "$effective_mode" == "auto" ]]; then
    if [[ -n "$support_keys" ]]; then effective_mode="key"; else effective_mode="password"; fi
  fi
  if [[ "$effective_mode" == "key" ]]; then
    support_keys="$(read_support_keys_strict "$SUPPORT_KEY_PATH")"
  fi
  if [[ "$effective_mode" == "password" ]]; then
    msg "No support public key found (or file is empty): ${SUPPORT_KEY_PATH:-<none>}"
    msg "Using temporary password account. (To use key auth, put your support team's OpenSSH public key(s) in support.pub.)"
  fi

  local remote_login_was_on="0"
  if remote_login_enabled; then remote_login_was_on="1"; fi

  local sshd_backup="${session_dir}/sshd_config.bak"
  backup_file "$sshd_config" "$sshd_backup" || true

  local ssh_user ssh_password temp_user
  ssh_user="$base_user"
  ssh_password=""
  temp_user=""

  local auth_keys=""
  local auth_backup="${session_dir}/authorized_keys.bak"
  local had_auth="0"
  if [[ "$effective_mode" == "key" ]]; then
    local ssh_dir="${base_home}/.ssh"
    auth_keys="${ssh_dir}/authorized_keys"
    ensure_dir "$ssh_dir"
    chown "$base_user" "$ssh_dir" || true
    chmod 700 "$ssh_dir" || true
    if backup_file "$auth_keys" "$auth_backup"; then had_auth="1"; fi
  else
    local up
    up="$(create_temp_user)" || { err "Failed to create temporary support user."; exit 1; }
    temp_user="${up%%:*}"
    ssh_password="${up#*:}"
    ssh_user="$temp_user"
  fi

  local bore_pid=""
  local relay_host=""
  local port=""
  local ssh_cmd=""
  local html_path=""
  local started_ok="0"
  local rollback_running="0"

  write_state() {
    cat >"$STATE_PATH" <<EOF
{
  "session_id": "${session_id}",
  "created_at": "${created_at}",
  "expires_at": "${expires_at}",
  "platform": "macos",
  "auth_mode": "${effective_mode}",
  "allow_lan": ${ALLOW_LAN},
  "target_user": "${base_user}",
  "target_user_home": "${base_home}",
  "support_key_path": "${SUPPORT_KEY_PATH}",
  "ssh_user": "${ssh_user}",
  "ssh_password": "${ssh_password}",
  "temp_user": "${temp_user}",
  "ssh_command": "${ssh_cmd}",
  "session_html": "${html_path}",
  "relay": "${RELAY}",
  "relay_host": "${relay_host}",
  "public_port": "${port}",
  "bore_pid": ${bore_pid:-0},
  "bore_out": "${bore_out:-}",
  "bore_err": "${bore_err:-}",
  "sshd_config": "${sshd_config}",
  "sshd_config_backup": "${sshd_backup}",
  "authorized_keys": "${auth_keys}",
  "authorized_keys_backup": ${had_auth},
  "remote_login_was_on": ${remote_login_was_on},
  "script_path": "${SELF_PATH}",
  "state_path": "${STATE_PATH}",
  "session_dir": "${session_dir}"
}
EOF
    chmod 600 "$STATE_PATH" >/dev/null 2>&1 || true
  }

  write_state

  rollback_start() {
    local rc="${1:-$?}"
    local line="${2:-}"
    local cmd="${3:-}"
    if [[ "$rollback_running" == "1" ]]; then
      exit "$rc"
    fi
    rollback_running="1"
    trap - EXIT INT TERM HUP ERR
    if [[ "$started_ok" == "1" ]]; then
      return 0
    fi
    if [[ -n "$line" && -n "$cmd" ]]; then
      warn "Error at line ${line}: ${cmd}"
    fi
    warn "Start failed; restoring previous configuration..."
    if [[ -n "$bore_pid" ]]; then
      kill "$bore_pid" >/dev/null 2>&1 || true
    fi
    if [[ -f "$sshd_backup" ]]; then
      cp -f "$sshd_backup" "$sshd_config" >/dev/null 2>&1 || true
    fi
    if [[ -n "$auth_keys" ]]; then
      if [[ "$had_auth" == "1" && -f "$auth_backup" ]]; then
        cp -f "$auth_backup" "$auth_keys" >/dev/null 2>&1 || true
      else
        rm -f "$auth_keys" >/dev/null 2>&1 || true
      fi
    fi
    if [[ -n "$temp_user" ]]; then
      delete_temp_user "$temp_user" || true
    fi
    if [[ "$remote_login_was_on" == "1" ]]; then
      set_remote_login on || true
    else
      set_remote_login off || true
    fi
    restart_sshd || true
    rm -f "$STATE_PATH" >/dev/null 2>&1 || true
    rm -rf "$session_dir" >/dev/null 2>&1 || true
    exit "$rc"
  }

  trap 'rollback_start $? ${LINENO} "$BASH_COMMAND"' ERR
  trap 'rollback_start $?' EXIT
  trap 'rollback_start 130' INT TERM HUP

  if [[ "$effective_mode" == "key" ]]; then
    # Append support keys during the session (do not wipe existing keys).
    {
      printf '\n'
      printf '# ssh-tool session %s BEGIN\n' "$session_id"
      printf '%s\n' "$support_keys"
      printf '# ssh-tool session %s END\n' "$session_id"
      printf '\n'
    } >>"$auth_keys"
    chown "$base_user" "$auth_keys" || true
    chmod 600 "$auth_keys" || true
  fi

  # Append sshd_config session settings; restore from backup on stop.
  local cfg_lines=("Port ${LOCAL_PORT}" "AllowUsers ${ssh_user}" "PubkeyAuthentication yes" "PermitRootLogin no")
  if [[ "$effective_mode" == "key" ]]; then
    cfg_lines+=("PasswordAuthentication no" "KbdInteractiveAuthentication no" "ChallengeResponseAuthentication no")
  else
    cfg_lines+=("PasswordAuthentication yes" "KbdInteractiveAuthentication yes" "ChallengeResponseAuthentication no")
  fi
  if [[ "$ALLOW_LAN" != "1" ]]; then
    cfg_lines+=("ListenAddress 127.0.0.1")
  fi

  # Remove conflicting directives first so our settings take effect.
  local sshd_tmp="${session_dir}/sshd_config.filtered"
  awk '
    {
      line=$0
      sub(/^[ \t]+/, "", line)
      if (line ~ /^#/) { print $0; next }
      split(line, a, /[ \t]+/)
      k=tolower(a[1])
      if (k=="listenaddress" || k=="port" || k=="allowusers" || k=="passwordauthentication" || k=="kbdinteractiveauthentication" || k=="challengeresponseauthentication" || k=="pubkeyauthentication" || k=="permitrootlogin") { next }
      print $0
    }
  ' "$sshd_config" >"$sshd_tmp"
  cat "$sshd_tmp" >"$sshd_config"
  append_marker_block "$sshd_config" "$session_id" "${cfg_lines[@]}"

  local sshd_test_err="${session_dir}/sshd_config.test.err"
  if ! /usr/sbin/sshd -t -f "$sshd_config" 2>"$sshd_test_err" >/dev/null; then
    err "sshd_config validation failed."
    if [[ -s "$sshd_test_err" ]]; then
      sed -n '1,120p' "$sshd_test_err" >&2 || true
    fi
    exit 1
  fi

  set_remote_login on
  restart_sshd

  local lan_note=""
  if [[ "$ALLOW_LAN" != "1" ]]; then
    # On macOS, launchd holds the listening socket for Remote Login, so sshd_config's
    # ListenAddress may not restrict the bind. We rely on AllowUsers + strong credentials.
    if lsof -nP -iTCP:"${LOCAL_PORT}" -sTCP:LISTEN 2>/dev/null | grep -E "TCP \\*:${LOCAL_PORT} \\(LISTEN\\)" >/dev/null 2>&1; then
      lan_note="macOS Remote Login listens on all interfaces; access is restricted by AllowUsers."
      warn "$lan_note"
    fi
  fi

  local bore_out="${session_dir}/bore.out.log"
  local bore_err="${session_dir}/bore.err.log"
  bore_pid="$(start_bore "$bore_out" "$bore_err")"
  write_state

  relay_host="$(relay_host_only "$RELAY")"
  if port="$(wait_bore_port "$relay_host" "$bore_out" "$bore_err")"; then
    :
  else
    warn "bore started but public port not detected yet. Check logs: ${bore_out} / ${bore_err}"
    port="PORT_FROM_LOGS"
  fi

  ssh_cmd="ssh ${ssh_user}@${relay_host} -p ${port}"
  copy_to_clipboard "$ssh_cmd"

  local note
  if [[ "$ALLOW_LAN" == "1" ]]; then
    note="LAN access is enabled."
  else
    if [[ -n "$lan_note" ]]; then note="$lan_note"; else note="SSH is bound to 127.0.0.1 (LAN blocked). Tunnel only."; fi
  fi

  html_path="${session_dir}/session.html"
  write_session_html "$html_path" "$ssh_cmd" "$expires_at" "$note" "$ssh_user" "$ssh_password"
  open_session_file "$html_path"
  write_state

  # Auto-stop in background (best-effort).
  nohup bash -c '
    sleep "$1" || true
    "$2" stop --state "$3" >/dev/null 2>&1 || true
  ' bash "$((MINUTES * 60))" "$SELF_PATH" "$STATE_PATH" >/dev/null 2>&1 &

  started_ok="1"
  trap - EXIT INT TERM HUP ERR

  msg "Session started. SSH command copied to clipboard:"
  printf '    %s\n' "$ssh_cmd"
  if [[ -n "$ssh_password" ]]; then
    msg "Password:"
    printf '    %s\n' "$ssh_password"
  fi
  msg "Expires at (UTC): $expires_at"
}

stop_session() {
  if need_root; then relaunch_sudo "$@"; fi

  local state_path="$STATE_PATH"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state) state_path="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ ! -f "$state_path" ]]; then
    if sshd_config_has_markers "/etc/ssh/sshd_config"; then
      warn "No active session state found: $state_path"
      warn "But sshd_config contains ssh-tool markers; attempting recovery..."
      recover_session --state "$state_path"
    fi
    msg "No active session."
    exit 0
  fi

  json_get_string() {
    local key="$1"
    sed -nE "s/^[[:space:]]*\\\"${key}\\\"[[:space:]]*:[[:space:]]*\\\"([^\\\"]*)\\\"[[:space:]]*,?[[:space:]]*$/\\1/p" "$state_path" | head -n 1
  }
  json_get_number() {
    local key="$1"
    sed -nE "s/^[[:space:]]*\\\"${key}\\\"[[:space:]]*:[[:space:]]*([0-9]+)[[:space:]]*,?[[:space:]]*$/\\1/p" "$state_path" | head -n 1
  }

  local bore_pid sshd_backup auth_backup_flag sshd_config remote_login_was_on session_dir auth_keys
  bore_pid="$(json_get_number "bore_pid" || true)"
  sshd_backup="$(json_get_string "sshd_config_backup" || true)"
  sshd_config="$(json_get_string "sshd_config" || true)"
  [[ -z "$sshd_config" ]] && sshd_config="/etc/ssh/sshd_config"
  auth_backup_flag="$(json_get_number "authorized_keys_backup" || true)"
  [[ -z "$auth_backup_flag" ]] && auth_backup_flag="0"
  remote_login_was_on="$(json_get_number "remote_login_was_on" || true)"
  [[ -z "$remote_login_was_on" ]] && remote_login_was_on="0"
  session_dir="$(json_get_string "session_dir" || true)"
  auth_keys="$(json_get_string "authorized_keys" || true)"
  local temp_user
  temp_user="$(json_get_string "temp_user" || true)"

  if [[ -n "$bore_pid" && "$bore_pid" != "0" ]]; then
    kill "$bore_pid" >/dev/null 2>&1 || true
  fi

  if [[ -n "$sshd_backup" && -f "$sshd_backup" ]]; then
    cp -f "$sshd_backup" "$sshd_config" || true
  fi

  # Restore authorized_keys if we had a backup; else remove markers file entirely.
  if [[ -n "$auth_keys" ]]; then
    if [[ "$auth_backup_flag" == "1" && -f "${session_dir}/authorized_keys.bak" ]]; then
      cp -f "${session_dir}/authorized_keys.bak" "$auth_keys" || true
    else
      rm -f "$auth_keys" >/dev/null 2>&1 || true
    fi
  fi

  if [[ -n "$temp_user" ]]; then
    delete_temp_user "$temp_user" || true
  fi

  if [[ "$remote_login_was_on" == "1" ]]; then
    set_remote_login on || warn "Failed to re-enable Remote Login."
  else
    set_remote_login off || warn "Failed to disable Remote Login."
  fi
  restart_sshd

  rm -f "$state_path" >/dev/null 2>&1 || true
  if [[ -n "$session_dir" && -d "$session_dir" ]]; then
    rm -rf "$session_dir" >/dev/null 2>&1 || true
  fi

  msg "Session stopped and configuration restored."
}

recover_session() {
  if need_root; then relaunch_sudo "$@"; fi

  local state_path="$STATE_PATH"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state) state_path="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -f "$state_path" ]]; then
    msg "State file found; stopping session normally..."
    stop_session --state "$state_path"
    return 0
  fi

  local sshd_config="/etc/ssh/sshd_config"
  if [[ ! -f "$sshd_config" ]]; then
    err "sshd_config not found: $sshd_config"
    exit 1
  fi

  local session_id
  session_id="$(sshd_config_last_marker_session_id "$sshd_config" || true)"
  if [[ -z "$session_id" ]]; then
    msg "Nothing to recover (no ssh-tool markers, no state file)."
    exit 0
  fi

  local allow_user=""
  allow_user="$(awk -v sid="$session_id" '
    $0 == "# ssh-tool session " sid " BEGIN" {in=1; next}
    $0 == "# ssh-tool session " sid " END" {in=0}
    in==1 && $1=="AllowUsers" {print $2; exit}
  ' "$sshd_config" 2>/dev/null || true)"

  local session_dir="${STATE_DIR}/sessions/${session_id}"
  local sshd_backup="${session_dir}/sshd_config.bak"

  warn "Recovering interrupted session ${session_id} (missing state file)..."

  if [[ -f "$sshd_backup" ]]; then
    cp -f "$sshd_backup" "$sshd_config" >/dev/null 2>&1 || true
  else
    warn "Backup not found (${sshd_backup}); removing marker block only."
    remove_marker_block "$sshd_config" "$session_id"
  fi

  if [[ -n "$allow_user" && "$allow_user" == support_* ]]; then
    delete_temp_user "$allow_user" || true
  fi

  # Best-effort cleanup for key mode: restore authorized_keys backup if present.
  if [[ -n "$allow_user" && "$allow_user" != support_* ]]; then
    local base_home auth_keys auth_backup
    base_home="$(get_user_home "$allow_user" 2>/dev/null || true)"
    auth_keys="${base_home}/.ssh/authorized_keys"
    auth_backup="${session_dir}/authorized_keys.bak"
    if [[ -f "$auth_backup" ]]; then
      cp -f "$auth_backup" "$auth_keys" >/dev/null 2>&1 || true
    else
      remove_marker_block "$auth_keys" "$session_id"
    fi
  fi

  # Without state we can't know the previous Remote Login setting; disable for safety.
  warn "Remote Login previous state is unknown; turning Remote Login off for safety."
  set_remote_login off || true
  restart_sshd || true

  rm -f "$state_path" >/dev/null 2>&1 || true
  rm -rf "$session_dir" >/dev/null 2>&1 || true

  msg "Recovery completed."
}

status_session() {
  if [[ ! -f "$STATE_PATH" ]]; then
    if sshd_config_has_markers "/etc/ssh/sshd_config"; then
      warn "Found ssh-tool markers in sshd_config but no state file."
      warn "Run: ${SELF_PATH} recover"
      exit 1
    fi
    msg "No active session."
    exit 0
  fi
  sed -nE 's/^[[:space:]]*"session_id"[[:space:]]*:[[:space:]]*"([^"]+)".*/Session: \\1/p;
           s/^[[:space:]]*"expires_at"[[:space:]]*:[[:space:]]*"([^"]+)".*/Expires: \\1/p;
           s/^[[:space:]]*"ssh_command"[[:space:]]*:[[:space:]]*"([^"]+)".*/SSH:     \\1/p;
           s/^[[:space:]]*"relay"[[:space:]]*:[[:space:]]*"([^"]+)".*/Relay:   \\1/p' "$STATE_PATH"
}

case "$ACTION" in
  start) start_session "$@" ;;
  stop) stop_session "$@" ;;
  status) status_session "$@" ;;
  recover) recover_session "$@" ;;
  *) err "Usage: $0 {start|stop|status|recover}"; exit 2 ;;
esac

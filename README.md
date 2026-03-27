# ssh-tool (Customer Remote Support)

`ssh-tool` is a temporary SSH remote support helper for customer machines. It is designed to start from a safe default: on Windows it does not expose SSH to the local network by default and instead uses `bore.pub` as the public relay, while macOS uses Remote Login plus the same relay model when needed. The tool can authenticate with a shipped support public key or fall back to a temporary account with a random password, and it includes explicit stop/recover paths so the session can be cleaned up after use.

## At A Glance

| Area | What this repo provides |
|---|---|
| Customer experience | A local UI for starting, stopping, and recovering a temporary support session |
| Network path | SSH access via `bore.pub` relay by default |
| Authentication | Support `support.pub` key, or a temporary user + random password when no key is provided |
| Platforms | Windows and macOS |
| Packaging | Release bundles, plus developer build scripts for ZIP, EXE, DMG, and MSI outputs |

## Supported Platforms

| Platform | Main release artifact | Other shipped format(s) |
|---|---|---|
| Windows x64 | `ssh-tool-win.exe` | `ssh-tool-win-offline.zip`, `ssh-tool-win.zip` |
| Windows ARM64 | `ssh-tool-win-arm64.exe` | `ssh-tool-win-offline.zip`, `ssh-tool-win.zip` |
| macOS Intel / Apple Silicon | `ssh-tool-mac.dmg` | `ssh-tool-mac.zip` |

## Development Status

- Current codebase version is `0.1.0`.
- The repo already has release packaging for Windows and macOS.
- The main supported workflows are the GUI-driven Windows/macOS bundles and the scripted ZIP flows.
- A Windows MSI build path exists for developers in `scripts/build-msi-win.sh`, but the primary release artifacts in the repo are the EXE/ZIP/DMG bundles.

## Known Limitations / Next Steps

- Windows support depends on OpenSSH Server being installed. In locked-down or offline environments, the offline bundle or `OpenSSH-Win64.zip` path is required.
- macOS support depends on `sudo` access for Remote Login and cleanup actions.
- The relay model depends on `bore.pub` or a locally available `bore` binary.
- The repo does not currently advertise an automated test suite in the docs; build scripts are the main verification path.
- If you need broader distribution formats or more environment-specific packaging, the existing MSI and offline bundle scripts are the natural next steps.

## Download and Install

👉 **Download the latest release here:** [Releases / Latest](../../releases/latest)

> Release downloads are in the **Assets** section of the release page. Do not use `Code -> Download ZIP`; that only contains source, not the packaged `.exe` / `.dmg` artifacts.

### Windows Quick Start

1. Download one of these:
   - Normal network environment: `ssh-tool-win.exe` or `ssh-tool-win-arm64.exe`
   - **Offline / Windows Update blocked**: `ssh-tool-win-offline.zip` and run the matching EXE after extracting it
2. Optionally place `support.pub` next to the EXE. This is recommended for passwordless support sessions.
3. Double-click the EXE and approve UAC.
   - If OpenSSH is not installed, the tool will try to install it first, which can take a few minutes.
4. The local page opens automatically. Click `Start Session`.
5. Send the displayed `ssh ...` command, and the password if one was generated, to the support engineer.
6. When finished, click `Stop (restore configuration)`.

Common Windows notes:

- If SmartScreen blocks the app, choose `More info` and then `Run anyway`.
- If OpenSSH Server installation fails, it is often because Windows Update or BITS is disabled, or because the machine cannot reach Microsoft update sources. In that case, ask IT to enable Windows Update or install `OpenSSH Server` from `Settings -> Apps -> Optional features`.
- For offline or policy-restricted environments, download `OpenSSH-Win64.zip` from PowerShell/Win32-OpenSSH, place it next to `ssh-tool-win.exe`, and name it `OpenSSH-Win64.zip`. The tool will unpack it to `C:\ProgramData\ssh-tool\openssh\` and register `sshd`.
- You can also override the zip path with `SSH_TOOL_OPENSSH_ZIP=C:\path\OpenSSH-Win64.zip`.

### Windows: Offline OpenSSH Install

When Windows Update is disabled, blocked by WSUS policy, or the machine is offline, `Add-WindowsCapability` may fail. Use the offline package flow instead:

1. Download `ssh-tool-win-offline.zip` from Releases, or obtain `OpenSSH-Win64.zip` from a machine with internet access.
2. Copy the zip to the target Windows machine and keep it alongside `ssh-tool-win.exe`:

```text
ssh-tool-win.exe
OpenSSH-Win64.zip
support.pub    (optional)
```

3. Run `ssh-tool-win.exe` and click `Start`.

Important:

- Fully extract the offline bundle first; do not run the EXE directly from inside the zip.
- Make sure `OpenSSH-Win64.zip` is in the same folder as the EXE.

Install / runtime locations:

- OpenSSH cache: `C:\ProgramData\ssh-tool\openssh\`
- Session state: `C:\ProgramData\ssh-tool\active-session.json`
- Runtime payload extraction: `%LOCALAPPDATA%\ssh-tool-win\payload-*` (`SSH_TOOL_PAYLOAD_DIR` can override this)

Optional environment variables:

- `SSH_TOOL_OPENSSH_ZIP=C:\path\OpenSSH-Win64.zip`
- `SSH_TOOL_OPENSSH_ZIP_URL=...` for a custom download URL

### macOS Quick Start

1. Download and open `ssh-tool-mac.dmg`.
2. Drag `SSH Tool.app` into `Applications`.
3. Double-click `SSH Tool.app`.
   - If no session is active, it starts a 60-minute temporary session.
   - If a session already exists, it performs stop/recover cleanup.
4. The session page opens automatically and shows the `ssh ...` command for the support engineer.
5. Use `Stop Session` or `Recover` from the page when you are done.

Common macOS notes:

- If macOS warns that the app cannot be opened, right-click `SSH Tool.app` and choose `Open`.
- If Gatekeeper quarantine needs to be cleared manually, run:

```bash
sudo xattr -dr com.apple.quarantine "/Applications/SSH Tool.app"
```

### macOS: Offline / Directory Notes

- The DMG and ZIP bundles include `bore`, so they should not need internet access. If you see `bore not found; downloading...`, the bundle is incomplete or files were removed; re-download the release or install it manually with `brew install bore-cli`.
- Default state directory: `/var/tmp/ssh-tool/` (`SSH_TOOL_STATE_DIR` can override this)
  - State file: `/var/tmp/ssh-tool/active-session.json` (`SSH_TOOL_STATE_PATH` can override this)
- `support.pub` behavior:
  - DMG: support public key is intended to be baked into the shipped bundle during release packaging
  - ZIP: users can edit `support.pub` directly in the extracted folder; leaving it empty falls back to temporary account + random password

## Safe Shutdown

When remote support is finished, close it in this order. Disconnecting the SSH client alone does **not** stop the tunnel or restore the system.

### 1. Close the SSH session from the support side

In the SSH window, run:

```bash
exit
```

That only disconnects the remote control session.

### 2. Stop the session on the customer machine

#### Windows

In the SSH Tool page, click:

- `Stop (restore configuration)`

The tool will then:

- Delete the temporary `support_****` user
- Stop `sshd`
- Close the `bore` tunnel
- Restore `sshd_config` and `authorized_keys`

If the page is stuck or the button is unavailable:

- Click `Recover (cleanup fallback)`
- Or run `.\ssh-tool-win.exe recover` from an elevated PowerShell

Manual fallback from elevated PowerShell:

```powershell
Stop-Service sshd -ErrorAction SilentlyContinue
taskkill /f /im bore.exe
# Replace support_**** with the temporary username shown in the UI/logs
net user support_**** /delete
```

#### macOS

Prefer the UI buttons:

- `Stop Session` to stop and restore immediately
- `Recover` for fallback cleanup

If the buttons are not available:

- Open `SSH Tool.app` again; if a session exists, it will stop and restore
- Or run the script version with:

```bash
./remote-support.sh stop
./remote-support.sh recover
```

### 3. Verify the shutdown

Have the support engineer try the same `ssh ...` command again. If it returns `Connection refused` or `closed`, the support session has been fully shut down.

## Security Model

- Windows does not expose SSH to the LAN by default: `sshd` is bound to `127.0.0.1` and only published through `bore.pub`.
- Public-key auth is preferred: if `support.pub` is present, password login is disabled.
- If no support key is present, the tool creates a temporary account with a random password.
- Sessions expire automatically and run `recover` to restore configuration and clean up the temporary user / tunnel.

## Advanced: Scripted ZIP Usage

<details>
<summary>Expand</summary>

### A) Windows ZIP

1. Download and extract `ssh-tool-win.zip`.
2. Optionally place your support team's public key in `support.pub`. If you leave it empty, the script switches to temporary account + random password mode.
3. Run PowerShell as administrator and start the session:

```powershell
.\remote-support.ps1 start -Minutes 60
```

The script will:

- Allow only public-key login if `support.pub` is provided
- Create a temporary account if `support.pub` is empty
- Bind `sshd` to `127.0.0.1`
- Start `bore` and copy the usable `ssh ...` command to the clipboard
- Automatically run `recover` at the end of the timer

Stop immediately:

```powershell
.\remote-support.ps1 stop
```

If the session state cannot be found, use fallback cleanup:

```powershell
.\remote-support.ps1 recover
```

### B) Windows EXE

1. Download `ssh-tool-win.exe` or `ssh-tool-win-arm64.exe`.
2. Optionally place `support.pub` next to the EXE. If it is missing, the tool falls back to temporary account + random password mode.
3. Double-click the EXE. It requests administrator privileges and opens the local UI. You can also run it from PowerShell:

```powershell
.\ssh-tool-win.exe start --minutes 60
```

Stop or recover:

```powershell
.\ssh-tool-win.exe stop
.\ssh-tool-win.exe recover
```

The EXE extracts its bundled `remote-support.ps1` and `bore.exe` to `%LOCALAPPDATA%\ssh-tool-win\payload-*`. Override the extraction directory with `SSH_TOOL_PAYLOAD_DIR` if needed.

### C) macOS ZIP

1. Download and extract `ssh-tool-mac.zip`.
2. Optionally place your support team's public key in `support.pub`. Leaving it empty enables temporary account + random password mode.
3. Run:

```bash
chmod +x ./remote-support.sh
./remote-support.sh start
```

Notes:

- The script prompts for `sudo`, because enabling Remote Login and restoring configuration require root.
- The bundle includes `bore` for Apple Silicon and Intel. If it is missing, the script will try to download it automatically. You can pin the version with `SSH_TOOL_BORE_VERSION`, or install it manually with `brew install bore-cli`.

Stop immediately:

```bash
./remote-support.sh stop
```

If session state is missing, run fallback cleanup:

```bash
./remote-support.sh recover
```

### D) macOS DMG

1. Download and open `ssh-tool-mac.dmg`.
2. Drag `SSH Tool.app` to `Applications`.
3. Double-click `SSH Tool.app`.
   - If no session exists, it starts a 60-minute temporary session.
   - If a session exists, it stops and restores.

The app opens a local page with the `ssh ...` command for the support engineer and the `Stop Session` / `Recover` buttons. The first launch will prompt for `sudo`, since Remote Login and cleanup require root.

</details>

## Developer Packaging

Run:

```bash
./scripts/build-release-zips.sh
```

This produces:

- `dist/ssh-tool-win.zip` - Windows script bundle with `bore.exe` and `support.pub`
- `dist/ssh-tool-win.exe` - Windows single-file EXE with bundled script + `bore.exe` + `support.pub`
- `dist/ssh-tool-mac.zip` - macOS script bundle with `bore` and `support.pub`
- `dist/ssh-tool-mac.dmg` - macOS distribution format for end users

Windows MSI packaging is available separately:

```bash
./scripts/build-msi-win.sh
```

That script auto-detects WiX v4 or `wixl`/msitools and emits `dist/ssh-tool-win.msi`.

## Repository Structure

- `packages/ssh-tool-win/` - Windows app, UI, scripts, `bore.exe`, and support key example
- `packages/ssh-tool-mac/` - macOS app, UI, scripts, and bundled `bore` binaries
- `scripts/` - release, EXE, DMG, MSI, and packaging helpers
- `build/` - MSI templates for Windows installer generation
- `keys/` - support-team public keys that are baked into release bundles

## Release Keys

If you are packaging customer builds, place one or more OpenSSH public keys in `keys/support.pub`. Keep the matching private key(s) on the support side only.

Then build the customer bundles:

```bash
./scripts/build-release-zips.sh
```

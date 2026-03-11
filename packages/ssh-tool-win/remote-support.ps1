param(
  [ValidateSet("start", "stop", "status", "recover")]
  [string]$Action = "start",

  [ValidateSet("auto", "key", "password")]
  [string]$AuthMode = "auto",

  [ValidateRange(1, 1440)]
  [int]$Minutes = 60,
  [string]$Relay = "bore.pub",
  [ValidateRange(1, 65535)]
  [int]$LocalPort = 22,

  [switch]$AllowLan,
  [string]$SupportKeyPath,
  [string]$StatePath,

  [string]$TargetUser,
  [string]$TargetUserHome
)

$ErrorActionPreference = "Stop"

function Test-IsAdmin {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Info([string]$Message) { Write-Host "[*] $Message" }
function Write-Warn([string]$Message) { Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Err([string]$Message) { Write-Host "[x] $Message" -ForegroundColor Red }

function Ensure-AdminRelaunch {
  if (Test-IsAdmin) { return }

  $user = if ($env:USERNAME) { $env:USERNAME } else { "" }
  $home = if ($env:USERPROFILE) { $env:USERPROFILE } else { "" }

  $args = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$PSCommandPath`"",
    "-Action", $Action,
    "-AuthMode", $AuthMode,
    "-Minutes", $Minutes,
    "-Relay", "`"$Relay`"",
    "-LocalPort", $LocalPort,
    "-TargetUser", "`"$user`"",
    "-TargetUserHome", "`"$home`""
  )

  if ($AllowLan) { $args += "-AllowLan" }
  if ($SupportKeyPath) { $args += @("-SupportKeyPath", "`"$SupportKeyPath`"") }
  if ($StatePath) { $args += @("-StatePath", "`"$StatePath`"") }

  Write-Info "Requesting administrator privileges..."
  Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args | Out-Null
  exit 0
}

function Get-DefaultStatePath {
  $base = Join-Path $env:ProgramData "ssh-tool"
  return Join-Path $base "active-session.json"
}

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Persist-SelfForCleanup([string]$BaseDir) {
  try {
    $dst = Join-Path $BaseDir "remote-support.ps1"
    if (-not (Test-Path -LiteralPath $dst)) {
      Copy-Item -LiteralPath $PSCommandPath -Destination $dst -Force
    } else {
      $srcInfo = Get-Item -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue
      $dstInfo = Get-Item -LiteralPath $dst -ErrorAction SilentlyContinue
      if ($srcInfo -and $dstInfo -and $srcInfo.LastWriteTimeUtc -gt $dstInfo.LastWriteTimeUtc) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $dst -Force
      }
    }
    return $dst
  } catch {
    return $PSCommandPath
  }
}

function Protect-PathAdminOnly([string]$Path) {
  try {
    & icacls $Path /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" | Out-Null
  } catch { }
}

function Write-State([hashtable]$State, [string]$Path) {
  $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
  Protect-PathAdminOnly $Path
}

function Read-SupportKeys([string]$Path) {
  if (-not $Path) { return @() }
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  $lines = Get-Content -LiteralPath $Path |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") }
  if (-not $lines -or $lines.Count -lt 1) { return @() }
  return @($lines)
}

function Read-SupportKeysStrict([string]$Path) {
  $keys = Read-SupportKeys $Path
  if (-not $keys -or $keys.Count -lt 1) { throw "Support key file is empty: $Path" }
  return $keys
}

function New-RandomPassword([int]$Length = 20) {
  $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $bytes = New-Object byte[] $Length
  $rng.GetBytes($bytes)
  return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function New-RandomSuffix([int]$Length = 4) {
  $chars = 'abcdefghijklmnopqrstuvwxyz0123456789'
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $bytes = New-Object byte[] $Length
  $rng.GetBytes($bytes)
  return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function New-TempLocalUser([int]$MaxRetries = 5) {
  for ($i = 0; $i -lt $MaxRetries; $i++) {
    $username = "support_{0}" -f (New-RandomSuffix)
    $existing = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
    if ($existing) { continue }

    $password = New-RandomPassword 20
    $secPass = ConvertTo-SecureString $password -AsPlainText -Force
    New-LocalUser -Name $username -Password $secPass -Description "Remote support temporary account" -PasswordNeverExpires -UserMayNotChangePassword -ErrorAction Stop | Out-Null
    Add-LocalGroupMember -Group "Users" -Member $username -ErrorAction SilentlyContinue
    return @{ user = $username; pass = $password }
  }
  throw "Failed to create temporary support user."
}

function Copy-TextToClipboard([string]$Text) {
  try {
    Set-Clipboard -Value $Text
  } catch {
    Write-Warn "Failed to copy to clipboard. You can still copy from the console/UI."
  }
}

function Relay-HostOnly([string]$RelayArg) {
  if (-not $RelayArg) { return "bore.pub" }
  if ($RelayArg.Contains(":")) { return $RelayArg.Split(":")[0] }
  return $RelayArg
}

function Backup-File([string]$Src, [string]$Dst) {
  if (Test-Path -LiteralPath $Src) {
    Copy-Item -LiteralPath $Src -Destination $Dst -Force
    return $true
  }
  return $false
}

function Install-OpenSSHServerIfMissing {
  $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
  if ($svc) { return }
  Write-Info "OpenSSH Server not found; installing..."
  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
}

function Get-ServiceStartMode([string]$Name) {
  $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
  if (-not $svc) { return $null }
  return $svc.StartMode
}

function Set-ServiceStartMode([string]$Name, [string]$Mode) {
  if (-not $Mode) { return }
  $modeLower = $Mode.ToLowerInvariant()
  if ($modeLower -eq "auto") { Set-Service -Name $Name -StartupType Automatic }
  elseif ($modeLower -eq "manual") { Set-Service -Name $Name -StartupType Manual }
  elseif ($modeLower -eq "disabled") { Set-Service -Name $Name -StartupType Disabled }
}

function Append-MarkerBlock([string]$Path, [string]$SessionId, [string[]]$Lines) {
  Add-Content -LiteralPath $Path -Encoding ASCII -Value ""
  Add-Content -LiteralPath $Path -Encoding ASCII -Value "# ssh-tool session $SessionId BEGIN"
  foreach ($l in $Lines) { Add-Content -LiteralPath $Path -Encoding ASCII -Value $l }
  Add-Content -LiteralPath $Path -Encoding ASCII -Value "# ssh-tool session $SessionId END"
}

function Insert-MarkerBlock-BeforeFirstMatch([string[]]$FileLines, [string]$SessionId, [string[]]$Lines) {
  $block = @("")
  $block += "# ssh-tool session $SessionId BEGIN"
  $block += $Lines
  $block += "# ssh-tool session $SessionId END"

  if (-not $FileLines) { return $block }

  $matchIndex = $null
  for ($i = 0; $i -lt $FileLines.Count; $i++) {
    if ($FileLines[$i] -match '^\s*Match\s') { $matchIndex = $i; break }
  }

  if ($null -eq $matchIndex) { return @($FileLines + $block) }
  if ($matchIndex -le 0) { return @($block + $FileLines) }

  $head = @($FileLines[0..($matchIndex - 1)])
  $tail = @($FileLines[$matchIndex..($FileLines.Count - 1)])
  return @($head + $block + $tail)
}

function Test-SshToolMarkersInFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
  if (-not $raw) { return $false }
  return [regex]::IsMatch($raw, '(?m)^# ssh-tool session [0-9a-f]{32} BEGIN$')
}

function Get-LastSshToolSessionIdFromFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
  if (-not $raw) { return $null }
  $matches = [regex]::Matches($raw, '(?m)^# ssh-tool session ([0-9a-f]{32}) BEGIN$')
  if ($matches.Count -lt 1) { return $null }
  return $matches[$matches.Count - 1].Groups[1].Value
}

function Remove-SshToolMarkerBlock([string]$Path, [string]$SessionId) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $lines = Get-Content -LiteralPath $Path -ErrorAction Stop
  $out = New-Object System.Collections.Generic.List[string]
  $skip = $false
  foreach ($line in $lines) {
    if ($line -eq "# ssh-tool session $SessionId BEGIN") { $skip = $true; continue }
    if ($line -eq "# ssh-tool session $SessionId END") { $skip = $false; continue }
    if (-not $skip) { [void]$out.Add($line) }
  }
  Set-Content -LiteralPath $Path -Encoding ASCII -Value $out
}

function Test-UserIsLocalAdmin([string]$User) {
  try {
    $members = Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop
    foreach ($m in $members) {
      if ($m.Name -match "\\\\$([regex]::Escape($User))$") { return $true }
    }
  } catch { }
  return $false
}

function Get-AuthorizedKeysInfo([string]$User, [string]$UserHome) {
  if (Test-UserIsLocalAdmin $User) {
    $p = Join-Path $env:ProgramData "ssh\administrators_authorized_keys"
    return @{ path = $p; is_admin_keys = $true; ssh_dir = $null }
  }
  $sshDir = Join-Path $UserHome ".ssh"
  $p = Join-Path $sshDir "authorized_keys"
  return @{ path = $p; is_admin_keys = $false; ssh_dir = $sshDir }
}

function Protect-AuthorizedKeys([string]$Path, [string]$User, [bool]$IsAdminKeys) {
  try {
    if ($IsAdminKeys) {
      & icacls $Path /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" | Out-Null
    } else {
      & icacls $Path /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" "$User:F" | Out-Null
    }
  } catch {
    Write-Warn "Failed to set permissions on authorized_keys. Key auth may not work until permissions are fixed."
  }
}

function Find-TempSupportUsers {
  try {
    return @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Name -like "support_*" -and $_.Description -eq "Remote support temporary account" })
  } catch {
    return @()
  }
}

function Html-Escape([string]$Text) {
  if ($null -eq $Text) { return "" }
  $t = [string]$Text
  $t = $t -replace "&", "&amp;"
  $t = $t -replace "<", "&lt;"
  $t = $t -replace ">", "&gt;"
  $t = $t -replace '"', "&quot;"
  $t = $t -replace "'", "&#39;"
  return $t
}

function New-SessionHtml([string]$Path, [hashtable]$State) {
  $cmd = Html-Escape $State.ssh_command
  $exp = Html-Escape $State.expires_at
  $warnLan = if ($State.allow_lan) { "LAN access is enabled." } else { "SSH is bound to 127.0.0.1 (LAN blocked). Tunnel only." }
  $warnLan = Html-Escape $warnLan
  $user = Html-Escape $State.ssh_user
  $passRow = ""
  if ($State.ssh_password) {
    $pass = Html-Escape $State.ssh_password
    $passRow = "<div>Password</div><div><b>$pass</b></div>"
  }

  $html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Remote Support Session</title>
  <style>
    :root{--bg0:#0b1020;--bg1:#0b1b2f;--card:rgba(255,255,255,.06);--text:rgba(255,255,255,.92);--muted:rgba(255,255,255,.62);--border:rgba(255,255,255,.12);--accent:#38bdf8;}
    *{box-sizing:border-box}
    body{margin:0;min-height:100vh;color:var(--text);font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial;background:
      radial-gradient(1200px 800px at 10% 10%, rgba(56,189,248,.18), transparent 60%),
      radial-gradient(900px 700px at 80% 30%, rgba(251,191,36,.12), transparent 55%),
      linear-gradient(160deg,var(--bg0),var(--bg1));}
    .wrap{max-width:980px;margin:0 auto;padding:28px 18px 44px}
    .card{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:16px 16px;backdrop-filter:blur(8px)}
    h1{margin:0 0 6px 0;font-size:22px}
    .sub{color:var(--muted);font-size:13px;margin-bottom:14px}
    .code{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono","Courier New",monospace;border:1px solid var(--border);background:rgba(0,0,0,.25);border-radius:12px;padding:12px 12px;overflow:auto;white-space:nowrap}
    .tip{color:var(--muted);font-size:12px;margin-top:10px}
    .kv{display:grid;grid-template-columns:140px 1fr;gap:8px 12px;margin-top:12px;color:var(--muted);font-size:13px}
    .kv b{color:var(--text);font-weight:600}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>Remote Support Session</h1>
      <div class="sub">Send the command below to support. This session auto-stops at the expiry time.</div>
      <div class="code">$cmd</div>
      <div class="kv">
        <div>User</div><div><b>$user</b></div>
        $passRow
        <div>Expires at</div><div><b>$exp</b></div>
        <div>Security</div><div><b>$warnLan</b></div>
      </div>
      <div class="tip">To stop immediately: run this script again with <b>stop</b>.</div>
    </div>
  </div>
</body>
</html>
"@
  Set-Content -LiteralPath $Path -Encoding UTF8 -Value $html
}

function Start-Session {
  Ensure-AdminRelaunch

  if (-not $SupportKeyPath) {
    $candidate = Join-Path $PSScriptRoot "support.pub"
    if (Test-Path -LiteralPath $candidate) { $SupportKeyPath = $candidate }
  }

  if (-not $TargetUser -or -not $TargetUserHome) {
    throw "TargetUser/TargetUserHome missing. Re-run without elevation and let the script elevate itself."
  }

  $supportKeys = Read-SupportKeys $SupportKeyPath
  $effectiveMode = $AuthMode
  if (-not $effectiveMode) { $effectiveMode = "auto" }
  if ($effectiveMode -eq "auto") {
    $effectiveMode = if ($supportKeys.Count -gt 0) { "key" } else { "password" }
  }
  if ($effectiveMode -eq "key" -and $supportKeys.Count -lt 1) {
    throw "Support public key is missing/empty. Put key(s) into support.pub, or use -AuthMode password."
  }

  $boreExe = Join-Path $PSScriptRoot "bore.exe"
  if (-not (Test-Path -LiteralPath $boreExe)) { throw "bore.exe not found next to script: $boreExe" }

  $sessionId = ([Guid]::NewGuid().ToString("N"))
  $createdAt = (Get-Date).ToUniversalTime()
  $expiresAt = $createdAt.AddMinutes([Math]::Max(1, $Minutes))

  $statePathFinal = if ($StatePath) { $StatePath } else { Get-DefaultStatePath }
  $baseDir = Split-Path -Parent $statePathFinal
  Ensure-Dir $baseDir
  $selfScript = Persist-SelfForCleanup -BaseDir $baseDir

  if (Test-Path -LiteralPath $statePathFinal) {
    throw "An active session already exists ($statePathFinal). Run: `"$selfScript`" -Action recover -StatePath `"$statePathFinal`""
  }

  $sessionDir = Join-Path $baseDir "sessions\$sessionId"
  Ensure-Dir $sessionDir

  $proc = $null
  $sshdConfig = "C:\ProgramData\ssh\sshd_config"
  $sshdBackup = Join-Path $sessionDir "sshd_config.bak"
  $authKeys = $null
  $authKeysBackup = $null
  $hadAuthKeys = $false
  $sshUser = $TargetUser
  $sshPassword = $null
  $tempUser = $null
  $originalWasRunning = $false
  $originalStartMode = $null
  $sshdWasPresentBefore = $false
  $relayHost = Relay-HostOnly $Relay

  $state = [ordered]@{
    session_id = $sessionId
    created_at = $createdAt.ToString("o")
    expires_at = $expiresAt.ToString("o")
    platform = "windows"
    auth_mode = $effectiveMode
    allow_lan = [bool]$AllowLan
    target_user = $TargetUser
    target_user_home = $TargetUserHome
    support_key_path = $SupportKeyPath
    ssh_user = $sshUser
    ssh_password = $sshPassword
    temp_user = $tempUser
    ssh_command = $null
    session_html = $null
    relay = $Relay
    relay_host = $relayHost
    public_port = $null
    bore_pid = $null
    bore_out = $null
    bore_err = $null
    sshd_config = $sshdConfig
    sshd_config_backup = $sshdBackup
    authorized_keys = $authKeys
    authorized_keys_backup = $null
    sshd_original_running = $null
    sshd_original_start_mode = $null
    sshd_was_present_before = $null
    script_path = $selfScript
    state_path = $statePathFinal
    session_dir = $sessionDir
  }

  Write-State -State $state -Path $statePathFinal
  Write-State -State $state -Path (Join-Path $sessionDir "state.json")

  try {
    $sshdWasPresentBefore = [bool](Get-Service -Name sshd -ErrorAction SilentlyContinue)

    Install-OpenSSHServerIfMissing

    if (-not (Test-Path -LiteralPath $sshdConfig)) {
      throw "sshd_config not found at $sshdConfig (OpenSSH Server install may have failed)."
    }

    if (Test-SshToolMarkersInFile $sshdConfig) {
      throw "Found ssh-tool markers in $sshdConfig (previous session not cleaned). Run: `"$selfScript`" -Action recover -StatePath `"$statePathFinal`""
    }

    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $service) { throw "sshd service not found after install." }

    $originalWasRunning = ($service.Status -eq "Running")
    $originalStartMode = Get-ServiceStartMode "sshd"
    $state.sshd_was_present_before = $sshdWasPresentBefore
    $state.sshd_original_running = $originalWasRunning
    $state.sshd_original_start_mode = $originalStartMode
    Write-State -State $state -Path $statePathFinal
    Write-State -State $state -Path (Join-Path $sessionDir "state.json")

    # If Disabled, enable temporarily so we can start it.
    if ($originalStartMode -and $originalStartMode.ToLowerInvariant() -eq "disabled") {
      Set-ServiceStartMode "sshd" "Manual"
    }

    Backup-File $sshdConfig $sshdBackup | Out-Null

    # Remove any existing conflicting directives so our session settings take effect.
    $directives = @(
      "ListenAddress",
      "Port",
      "AllowUsers",
      "PasswordAuthentication",
      "KbdInteractiveAuthentication",
      "ChallengeResponseAuthentication",
      "PubkeyAuthentication",
      "PermitRootLogin"
    )
    $raw = Get-Content -LiteralPath $sshdConfig -Raw -ErrorAction Stop
    $lines = $raw -split "`r?`n", -1
    $rx = '^\s*(' + (($directives | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\b'
    $filtered = @()
    foreach ($line in $lines) {
      $trim = $line.TrimStart()
      if ($trim.StartsWith("#")) { $filtered += $line; continue }
      if ($line -match $rx) { continue }
      $filtered += $line
    }
    # Insert our temporary session directives into the global section, BEFORE any "Match" block.
    # In sshd_config, a Match block applies to the rest of the file; directives like "Port" are
    # invalid inside Match. Windows' default sshd_config often ends with a Match block.

    $configLines = @(
      "Port $LocalPort",
      "PubkeyAuthentication yes",
      "PermitRootLogin no"
    )
    if ($effectiveMode -eq "key") {
      $configLines += @(
        "PasswordAuthentication no",
        "KbdInteractiveAuthentication no",
        "ChallengeResponseAuthentication no"
      )
    } else {
      $configLines += @(
        "PasswordAuthentication yes",
        "KbdInteractiveAuthentication yes",
        "ChallengeResponseAuthentication no"
      )
      $temp = New-TempLocalUser
      $tempUser = $temp.user
      $sshUser = $temp.user
      $sshPassword = $temp.pass
      Write-Warn "No support key found; using temporary password account: $tempUser"
    }
    $configLines += "AllowUsers $sshUser"
    $state.ssh_user = $sshUser
    $state.ssh_password = $sshPassword
    $state.temp_user = $tempUser
    Write-State -State $state -Path $statePathFinal
    Write-State -State $state -Path (Join-Path $sessionDir "state.json")
    if (-not $AllowLan) {
      $configLines += "ListenAddress 127.0.0.1"
    }
    $finalLines = Insert-MarkerBlock-BeforeFirstMatch -FileLines $filtered -SessionId $sessionId -Lines $configLines
    Set-Content -LiteralPath $sshdConfig -Encoding ASCII -Value $finalLines

    # Validate sshd_config if sshd.exe is available.
    $sshdExe = Join-Path $env:WINDIR "System32\OpenSSH\sshd.exe"
    if (Test-Path -LiteralPath $sshdExe) {
      & $sshdExe -t -f $sshdConfig | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "sshd_config validation failed (sshd.exe -t returned $LASTEXITCODE)" }
    }

    try { Restart-Service sshd -ErrorAction Stop } catch { Start-Service sshd }

    $listenConns = @(Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue)
    if (-not $listenConns -or $listenConns.Count -lt 1) {
      throw "sshd is not listening on port $LocalPort after restart."
    }
    if (-not $AllowLan) {
      $bad = @($listenConns | Select-Object -ExpandProperty LocalAddress -Unique | Where-Object { $_ -ne "127.0.0.1" -and $_ -ne "::1" })
      if ($bad.Count -gt 0) {
        throw ("sshd is listening on non-loopback address(es): " + ($bad -join ", "))
      }
    }

    if ($effectiveMode -eq "key") {
      $supportKeys = Read-SupportKeysStrict $SupportKeyPath
      $ak = Get-AuthorizedKeysInfo -User $TargetUser -UserHome $TargetUserHome
      if ($ak.ssh_dir) { Ensure-Dir $ak.ssh_dir }
      $authKeys = $ak.path
      $authKeysBackup = Join-Path $sessionDir "authorized_keys.bak"
      $hadAuthKeys = Backup-File $authKeys $authKeysBackup

      if (-not (Test-Path -LiteralPath $authKeys)) {
        New-Item -ItemType File -Path $authKeys -Force | Out-Null
      }
      Append-MarkerBlock -Path $authKeys -SessionId $sessionId -Lines $supportKeys
      Protect-AuthorizedKeys -Path $authKeys -User $TargetUser -IsAdminKeys ([bool]$ak.is_admin_keys)

      $state.authorized_keys = $authKeys
      $state.authorized_keys_backup = if ($hadAuthKeys) { $authKeysBackup } else { $null }
      Write-State -State $state -Path $statePathFinal
      Write-State -State $state -Path (Join-Path $sessionDir "state.json")
    }

    $boreOut = Join-Path $sessionDir "bore.out.log"
    $boreErr = Join-Path $sessionDir "bore.err.log"

    $proc = Start-Process -FilePath $boreExe -ArgumentList @("local", "$LocalPort", "--to", "$Relay") -PassThru -WindowStyle Hidden -RedirectStandardOutput $boreOut -RedirectStandardError $boreErr
    $state.bore_pid = $proc.Id
    $state.bore_out = $boreOut
    $state.bore_err = $boreErr
    Write-State -State $state -Path $statePathFinal
    Write-State -State $state -Path (Join-Path $sessionDir "state.json")

    $port = $null
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline -and -not $port) {
      Start-Sleep -Milliseconds 500
      $text = ""
      if (Test-Path -LiteralPath $boreOut) { $text += (Get-Content -LiteralPath $boreOut -Tail 50 -ErrorAction SilentlyContinue | Out-String) }
      if (Test-Path -LiteralPath $boreErr) { $text += (Get-Content -LiteralPath $boreErr -Tail 50 -ErrorAction SilentlyContinue | Out-String) }
      $m = [regex]::Match($text, [regex]::Escape($relayHost) + ":(\d+)")
      if ($m.Success) { $port = $m.Groups[1].Value }
    }

    if (-not $port) {
      Write-Warn "bore started but public port not detected yet. Check logs: $boreOut / $boreErr"
    }

    $sshCmd = if ($port) { "ssh $sshUser@$relayHost -p $port" } else { "ssh $sshUser@$relayHost -p PORT_FROM_LOGS" }
    Copy-TextToClipboard $sshCmd

    $state.public_port = $port
    $state.ssh_command = $sshCmd
    Write-State -State $state -Path $statePathFinal
    Write-State -State $state -Path (Join-Path $sessionDir "state.json")

    $htmlPath = Join-Path $sessionDir "session.html"
    New-SessionHtml -Path $htmlPath -State $state
    $state.session_html = $htmlPath
    Write-State -State $state -Path $statePathFinal
    Write-State -State $state -Path (Join-Path $sessionDir "state.json")
    if (-not $env:SSH_TOOL_NO_OPEN_HTML) {
      try { Start-Process -FilePath $htmlPath | Out-Null } catch { }
    }

    # Auto-stop in background.
    $seconds = [int][Math]::Max(60, [Math]::Round(($expiresAt - (Get-Date).ToUniversalTime()).TotalSeconds))
    $cmd = "Start-Sleep -Seconds $seconds; & `"$selfScript`" -Action recover -StatePath `"$statePathFinal`""
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-Command", $cmd) -WindowStyle Hidden | Out-Null

    Write-Info "Session started. SSH command copied to clipboard:"
    Write-Host "    $sshCmd"
    if ($sshPassword) {
      Write-Info "Password:"
      Write-Host "    $sshPassword"
    }
    Write-Info "Expires at (UTC): $($expiresAt.ToString('u'))"
  } catch {
    Write-Err ("Start failed: " + $_.Exception.Message)

    # Best-effort rollback.
    if ($proc) {
      try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($tempUser) {
      try { Remove-LocalUser -Name $tempUser -ErrorAction SilentlyContinue } catch { }
      try {
        $profilePath = "C:\Users\$tempUser"
        if (Test-Path -LiteralPath $profilePath) { Remove-Item -LiteralPath $profilePath -Recurse -Force -ErrorAction SilentlyContinue }
      } catch { }
    }
    if ($sshdBackup -and (Test-Path -LiteralPath $sshdBackup)) {
      try { Copy-Item -LiteralPath $sshdBackup -Destination $sshdConfig -Force } catch { }
    }
    if ($authKeysBackup -and (Test-Path -LiteralPath $authKeysBackup)) {
      try { Copy-Item -LiteralPath $authKeysBackup -Destination $authKeys -Force } catch { }
    } elseif ($authKeys -and (Test-Path -LiteralPath $authKeys)) {
      try { Remove-Item -LiteralPath $authKeys -Force -ErrorAction SilentlyContinue } catch { }
    }

    try { Restart-Service sshd -ErrorAction SilentlyContinue } catch { }
    if ($originalStartMode) {
      try { Set-ServiceStartMode "sshd" $originalStartMode } catch { }
    }
    if (-not $originalWasRunning) {
      try { Stop-Service sshd -ErrorAction SilentlyContinue } catch { }
    }
    if (-not $sshdWasPresentBefore) {
      try { Stop-Service sshd -ErrorAction SilentlyContinue } catch { }
      try { Set-ServiceStartMode "sshd" "Disabled" } catch { }
    }

    try { if (Test-Path -LiteralPath $statePathFinal) { Remove-Item -LiteralPath $statePathFinal -Force -ErrorAction SilentlyContinue } } catch { }
    try { if (Test-Path -LiteralPath $sessionDir) { Remove-Item -LiteralPath $sessionDir -Recurse -Force -ErrorAction SilentlyContinue } } catch { }

    throw
  }
}

function Stop-Session {
  Ensure-AdminRelaunch

  $statePathFinal = if ($StatePath) { $StatePath } else { Get-DefaultStatePath }
  if (-not (Test-Path -LiteralPath $statePathFinal)) {
    $sshdConfig = "C:\ProgramData\ssh\sshd_config"
    if (Test-SshToolMarkersInFile $sshdConfig) {
      Write-Warn "No active session state found: $statePathFinal"
      Write-Warn "But sshd_config contains ssh-tool markers; attempting recovery..."
      Recover-Session
      return
    }
    Write-Info "No active session."
    return
  }

  try {
    $state = Get-Content -LiteralPath $statePathFinal -Raw | ConvertFrom-Json
  } catch {
    Write-Warn "Failed to read/parse session state; attempting recovery..."
    Recover-Session
    return
  }

  # Stop bore
  if ($state.bore_pid) {
    try { Stop-Process -Id $state.bore_pid -Force -ErrorAction SilentlyContinue } catch { }
  }

  # Delete temporary user (password mode)
  if ($state.temp_user) {
    try { Remove-LocalUser -Name $state.temp_user -ErrorAction SilentlyContinue } catch { }
    try {
      $profilePath = "C:\Users\$($state.temp_user)"
      if (Test-Path -LiteralPath $profilePath) {
        Remove-Item -LiteralPath $profilePath -Recurse -Force -ErrorAction SilentlyContinue
      }
    } catch { }
  }

  # Restore sshd_config
  if ($state.sshd_config_backup -and (Test-Path -LiteralPath $state.sshd_config_backup)) {
    Copy-Item -LiteralPath $state.sshd_config_backup -Destination $state.sshd_config -Force
  }

  # Restore authorized_keys
  if ($state.authorized_keys_backup -and (Test-Path -LiteralPath $state.authorized_keys_backup)) {
    Copy-Item -LiteralPath $state.authorized_keys_backup -Destination $state.authorized_keys -Force
  } else {
    # No original file; remove the one we created.
    if ($state.authorized_keys -and (Test-Path -LiteralPath $state.authorized_keys)) {
      Remove-Item -LiteralPath $state.authorized_keys -Force -ErrorAction SilentlyContinue
    }
  }

  # Restart sshd to apply restored config, then restore original running/start mode.
  try { Restart-Service sshd -ErrorAction SilentlyContinue } catch { }

  if ($state.sshd_original_start_mode) {
    try { Set-ServiceStartMode "sshd" $state.sshd_original_start_mode } catch { }
  }

  if (-not $state.sshd_original_running) {
    try { Stop-Service sshd -ErrorAction SilentlyContinue } catch { }
  }

  if ($state.sshd_was_present_before -eq $false) {
    # Service was installed by this session; disable it to reduce footprint.
    try { Stop-Service sshd -ErrorAction SilentlyContinue } catch { }
    try { Set-ServiceStartMode "sshd" "Disabled" } catch { }
  }

  # Cleanup state + session dir
  try { Remove-Item -LiteralPath $statePathFinal -Force -ErrorAction SilentlyContinue } catch { }
  if ($state.session_dir -and (Test-Path -LiteralPath $state.session_dir)) {
    try { Remove-Item -LiteralPath $state.session_dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }

  Write-Info "Session stopped and configuration restored."
}

function Recover-Session {
  Ensure-AdminRelaunch

  $statePathFinal = if ($StatePath) { $StatePath } else { Get-DefaultStatePath }
  if (Test-Path -LiteralPath $statePathFinal) {
    try {
      $null = Get-Content -LiteralPath $statePathFinal -Raw | ConvertFrom-Json
      Stop-Session
      return
    } catch {
      Write-Warn "State file exists but is not valid JSON; proceeding with recovery..."
    }
  }

  $sshdConfig = "C:\ProgramData\ssh\sshd_config"
  if (-not (Test-Path -LiteralPath $sshdConfig)) {
    Write-Err "sshd_config not found at $sshdConfig"
    return
  }

  $sessionId = Get-LastSshToolSessionIdFromFile $sshdConfig
  if (-not $sessionId) {
    Write-Info "Nothing to recover."
    return
  }

  $baseDir = Split-Path -Parent $statePathFinal
  $sessionDir = Join-Path $baseDir "sessions\$sessionId"
  $sessionStatePath = Join-Path $sessionDir "state.json"
  $state = $null
  if (Test-Path -LiteralPath $sessionStatePath) {
    try { $state = Get-Content -LiteralPath $sessionStatePath -Raw | ConvertFrom-Json } catch { }
  }

  # Stop bore
  if ($state -and $state.bore_pid) {
    try { Stop-Process -Id $state.bore_pid -Force -ErrorAction SilentlyContinue } catch { }
  }

  # Restore sshd_config
  $backup = $null
  if ($state -and $state.sshd_config_backup) { $backup = $state.sshd_config_backup }
  else { $backup = Join-Path $sessionDir "sshd_config.bak" }

  if ($backup -and (Test-Path -LiteralPath $backup)) {
    try { Copy-Item -LiteralPath $backup -Destination $sshdConfig -Force } catch { }
  } else {
    try { Remove-SshToolMarkerBlock -Path $sshdConfig -SessionId $sessionId } catch { }
  }

  # Restore authorized_keys (best-effort)
  if ($state -and $state.authorized_keys_backup -and (Test-Path -LiteralPath $state.authorized_keys_backup)) {
    try { Copy-Item -LiteralPath $state.authorized_keys_backup -Destination $state.authorized_keys -Force } catch { }
  } elseif ($state -and $state.authorized_keys -and (Test-Path -LiteralPath $state.authorized_keys)) {
    try { Remove-SshToolMarkerBlock -Path $state.authorized_keys -SessionId $sessionId } catch { }
  }

  # Delete temporary user(s)
  $tempUsers = @()
  if ($state -and $state.temp_user) {
    $tempUsers = @($state.temp_user)
  } else {
    $tempUsers = @(Find-TempSupportUsers | Select-Object -ExpandProperty Name)
  }
  foreach ($u in $tempUsers) {
    if (-not $u) { continue }
    try { Remove-LocalUser -Name $u -ErrorAction SilentlyContinue } catch { }
    try {
      $profilePath = "C:\Users\$u"
      if (Test-Path -LiteralPath $profilePath) {
        Remove-Item -LiteralPath $profilePath -Recurse -Force -ErrorAction SilentlyContinue
      }
    } catch { }
  }

  # Restart sshd and restore original running/start mode if available.
  try { Restart-Service sshd -ErrorAction SilentlyContinue } catch { }
  if ($state -and $state.sshd_original_start_mode) {
    try { Set-ServiceStartMode "sshd" $state.sshd_original_start_mode } catch { }
  }
  if ($state -and ($state.sshd_original_running -eq $false)) {
    try { Stop-Service sshd -ErrorAction SilentlyContinue } catch { }
  }
  if ($state -and ($state.sshd_was_present_before -eq $false)) {
    try { Stop-Service sshd -ErrorAction SilentlyContinue } catch { }
    try { Set-ServiceStartMode "sshd" "Disabled" } catch { }
  }

  if (Test-Path -LiteralPath $sessionDir) {
    try { Remove-Item -LiteralPath $sessionDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }
  try { if (Test-Path -LiteralPath $statePathFinal) { Remove-Item -LiteralPath $statePathFinal -Force -ErrorAction SilentlyContinue } } catch { }

  Write-Info "Recovery completed."
}

function Show-Status {
  Ensure-AdminRelaunch
  $statePathFinal = if ($StatePath) { $StatePath } else { Get-DefaultStatePath }
  if (-not (Test-Path -LiteralPath $statePathFinal)) {
    $sshdConfig = "C:\ProgramData\ssh\sshd_config"
    if (Test-SshToolMarkersInFile $sshdConfig) {
      $sid = Get-LastSshToolSessionIdFromFile $sshdConfig
      Write-Warn "Found ssh-tool markers in sshd_config but no state file."
      if ($sid) { Write-Warn "Session: $sid" }
      Write-Warn "Run: `"$PSCommandPath`" -Action recover"
      return
    }
    Write-Info "No active session."
    return
  }
  $state = Get-Content -LiteralPath $statePathFinal -Raw | ConvertFrom-Json
  Write-Host "Session: $($state.session_id)"
  Write-Host "Expires: $($state.expires_at)"
  Write-Host "SSH:     $($state.ssh_command)"
  Write-Host "Relay:   $($state.relay)"
}

if ($Action -eq "start") { Start-Session }
elseif ($Action -eq "stop") { Stop-Session }
elseif ($Action -eq "status") { Show-Status }
elseif ($Action -eq "recover") { Recover-Session }

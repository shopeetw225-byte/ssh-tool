$ErrorActionPreference = "Stop"

Set-Location -Path $PSScriptRoot

if (-not $env:SSH_TOOL_TOKEN -or $env:SSH_TOOL_TOKEN.Trim().Length -lt 12) {
  $env:SSH_TOOL_TOKEN = [Guid]::NewGuid().ToString("N")
}

Write-Host "SSH Tool token (x-ssh-tool-token): $env:SSH_TOOL_TOKEN"
Write-Host "Opening http://127.0.0.1:3000 ..."
Start-Sleep -Milliseconds 300
Start-Process "http://127.0.0.1:3000"

node app.js


@echo off
chcp 65001 >nul 2>&1
title Remote Support (SSH) - Stop

:: Run with admin privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
  exit /b
)

powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0remote-support.ps1" -Action recover

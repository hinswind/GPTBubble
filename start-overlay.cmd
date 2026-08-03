@echo off
start "Codex Usage Overlay" /min "C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -STA -WindowStyle Hidden -File "%~dp0CodexUsageOverlay.ps1"

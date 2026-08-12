@echo off
start "Codex Usage Overlay" /min "C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Run-GPTBubble.ps1" -ClearStopMarker

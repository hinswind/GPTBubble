$ErrorActionPreference = 'Stop'

$projectDirectory = Split-Path -Parent $PSCommandPath
$overlayScript = Join-Path $projectDirectory 'CodexUsageOverlay.ps1'
$pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
$startupDirectory = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDirectory 'Codex Usage Overlay.lnk'

if (-not (Test-Path -LiteralPath $pwshPath)) {
    throw "未找到 PowerShell 7：$pwshPath"
}
if (-not (Test-Path -LiteralPath $overlayScript)) {
    throw "未找到浮层脚本：$overlayScript"
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $pwshPath
$shortcut.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$overlayScript`""
$shortcut.WorkingDirectory = $projectDirectory
$shortcut.Description = 'Codex 用量浮层（登录 Windows 后自动启动）'
$shortcut.Save()

Get-Item -LiteralPath $shortcutPath | Select-Object Name, FullName, Length, LastWriteTime

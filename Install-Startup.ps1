[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

$projectDirectory = Split-Path -Parent $PSCommandPath
$runnerScript = Join-Path $projectDirectory 'Run-GPTBubble.ps1'
$pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
$taskName = 'GPTBubble'
$startupDirectory = [Environment]::GetFolderPath('Startup')
$legacyShortcutPath = Join-Path $startupDirectory 'Codex Usage Overlay.lnk'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $legacyShortcutPath) {
        Remove-Item -LiteralPath $legacyShortcutPath -Force
    }
    [pscustomobject]@{
        TaskName = $taskName
        Installed = $false
        Message = '已移除计划任务和旧版启动快捷方式。'
    }
    return
}

if (-not (Test-Path -LiteralPath $pwshPath)) {
    throw "未找到 PowerShell 7：$pwshPath"
}
if (-not (Test-Path -LiteralPath $runnerScript)) {
    throw "未找到启动器：$runnerScript"
}

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $runnerScript
$action = New-ScheduledTaskAction `
    -Execute $pwshPath `
    -Argument $arguments `
    -WorkingDirectory $projectDirectory
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$healthTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal `
    -UserId $currentUser `
    -LogonType Interactive `
    -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 20 `
    -RestartInterval (New-TimeSpan -Minutes 1)
$task = New-ScheduledTask `
    -Action $action `
    -Trigger @($trigger, $healthTrigger) `
    -Principal $principal `
    -Settings $settings `
    -Description 'Codex 用量浮层；异常退出后自动重启，正常退出后保持关闭。'

Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null

# Remove the old one-shot startup entry only after the resilient task is registered.
if (Test-Path -LiteralPath $legacyShortcutPath) {
    Remove-Item -LiteralPath $legacyShortcutPath -Force
}
$stopMarkerPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GPTBubble\stopped.session'
if (Test-Path -LiteralPath $stopMarkerPath) {
    Remove-Item -LiteralPath $stopMarkerPath -Force
}

if (-not $NoStart) {
    Start-ScheduledTask -TaskName $taskName
}

$registeredTask = Get-ScheduledTask -TaskName $taskName
[pscustomobject]@{
    TaskName = $registeredTask.TaskName
    State = $registeredTask.State
    User = $currentUser
    RestartCount = $registeredTask.Settings.RestartCount
    RestartInterval = $registeredTask.Settings.RestartInterval
    HealthCheckInterval = 'PT1M'
    LogPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GPTBubble\GPTBubble.log'
}

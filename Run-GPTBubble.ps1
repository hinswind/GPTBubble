[CmdletBinding()]
param(
    [int]$RefreshSeconds = 60,
    [string]$OverlayScriptPath,
    [string]$LogPath,
    [string]$StopMarkerPath,
    [switch]$ClearStopMarker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runnerCreatedNew = $false
$script:runnerMutex = [Threading.Mutex]::new(
    $true,
    'Local\GPTBubbleRunner',
    [ref]$runnerCreatedNew
)
if (-not $runnerCreatedNew) {
    $script:runnerMutex.Dispose()
    exit 0
}

if (-not $OverlayScriptPath) {
    $OverlayScriptPath = Join-Path $PSScriptRoot 'CodexUsageOverlay.ps1'
}
if (-not $LogPath) {
    $logDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GPTBubble'
    $LogPath = Join-Path $logDirectory 'GPTBubble.log'
}
if (-not $StopMarkerPath) {
    $StopMarkerPath = Join-Path (Split-Path -Parent $LogPath) 'stopped.session'
}

function Get-CurrentSessionKey {
    $bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks
    return '{0}|{1}' -f ([Diagnostics.Process]::GetCurrentProcess().SessionId), $bootTime
}

function Write-GPTBubbleLog([string]$Level, [string]$Message) {
    try {
        $logDirectory = Split-Path -Parent $LogPath
        if (-not (Test-Path -LiteralPath $logDirectory)) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        if ((Test-Path -LiteralPath $LogPath) -and
            (Get-Item -LiteralPath $LogPath).Length -ge 1MB) {
            $archivePath = "$LogPath.previous"
            Move-Item -LiteralPath $LogPath -Destination $archivePath -Force
        }
        $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never prevent the overlay from starting or stopping.
    }
}

try {
    if (-not (Test-Path -LiteralPath $OverlayScriptPath)) {
        throw "未找到浮层脚本：$OverlayScriptPath"
    }

    if ($ClearStopMarker -and (Test-Path -LiteralPath $StopMarkerPath)) {
        Remove-Item -LiteralPath $StopMarkerPath -Force
    }
    if (Test-Path -LiteralPath $StopMarkerPath) {
        $stoppedSession = (Get-Content -LiteralPath $StopMarkerPath -Raw -Encoding UTF8).Trim()
        if ($stoppedSession -eq (Get-CurrentSessionKey)) {
            Write-GPTBubbleLog 'INFO' '本次登录会话已由用户主动退出，跳过健康检查启动'
            exit 0
        }
        Remove-Item -LiteralPath $StopMarkerPath -Force
    }

    Write-GPTBubbleLog 'INFO' "启动浮层（PID=$PID）"
    & $OverlayScriptPath -RefreshSeconds $RefreshSeconds -StopMarkerPath $StopMarkerPath
    Write-GPTBubbleLog 'INFO' '浮层正常退出'
    exit 0
}
catch {
    $detail = ($_ | Out-String).Trim() -replace "`r?`n", ' | '
    Write-GPTBubbleLog 'ERROR' $detail
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 1
}

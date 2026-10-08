$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null; $parseErrors = $null
$overlay = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'CodexUsageOverlay.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors | Out-String) }
Add-Type -AssemblyName PresentationFramework
foreach ($name in @('Update-ResetCreditBadge', 'Get-UiBrush')) {
    $function = $overlay.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
}
function Write-ResetBadgeState { param($count, $expiry, $color) }
$resetCreditBadge = [Windows.Controls.Border]::new()
$resetCreditCountText = [Windows.Controls.TextBlock]::new()
$resetCreditToolTipText = [Windows.Controls.TextBlock]::new()
$epoch = 1800000000L
$data = [pscustomobject]@{ rateLimitResetCredits = [pscustomobject]@{
    availableCount = 2
    credits = @(
        [pscustomobject]@{status='available'; expiresAt=$epoch + 4*86400},
        [pscustomobject]@{status='available'; expiresAt=$epoch + 20*86400}
    )
} }
# 同一份缓存数据，仅推进时间：绿色 → 橙色 → 红色 → 下一笔绿色。
foreach ($case in @(@(0,'#FF6FC68A'), @(86400,'#FFF0A84F'), @(259200,'#FFE47D76'), @(345600,'#FF6FC68A'))) {
    Update-ResetCreditBadge $data ($epoch + $case[0])
    if ($resetCreditBadge.Background.ToString() -ne $case[1]) { throw "Unexpected color at $($case[0])" }
}
$data.rateLimitResetCredits.availableCount = 0
Update-ResetCreditBadge $data $epoch
if ($resetCreditBadge.Visibility -ne 'Collapsed') { throw 'Zero count must hide badge' }
Write-Output 'PASS: cached expiry crosses green/orange/red and switches to next credit'

$watcherPath = Join-Path $root 'Watch-CodexUsage.ps1'
$watcher = [Management.Automation.Language.Parser]::ParseFile($watcherPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors | Out-String) }
$resolver = $watcher.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-CodexRuntime'}, $true)
$fakeServer = (Join-Path $PSScriptRoot 'UnresponsiveServer.ps1').Replace("'", "''")
$pwsh = (Join-Path $PSHOME 'pwsh.exe').Replace("'", "''")
$replacement = "function Resolve-CodexRuntime { [pscustomobject]@{NodePath='$pwsh'; CodexScript='$fakeServer'} }"
$source = $watcher.Extent.Text.Replace($resolver.Extent.Text, $replacement)
$marker = Join-Path $env:TEMP 'gptbubble-timeout-test.marker'
if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker }
$queue = [Collections.Concurrent.ConcurrentQueue[string]]::new()
$job = Start-ThreadJob -ScriptBlock { param($source, $queue) & ([scriptblock]::Create($source)) -CommandQueue $queue -RequestTimeoutSeconds 1 } -ArgumentList $source,$queue
$timedOut = $false; $recovered = $false
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline -and -not $recovered) {
        foreach ($line in @(Receive-Job $job)) {
            $event = $line | ConvertFrom-Json
            if ($event.kind -eq 'error' -and $event.message -match '超过 1 秒') { $timedOut = $true }
            if ($event.kind -eq 'usage' -and $event.data.recovered) { $recovered = $true }
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $timedOut -or -not $recovered) { throw "Timeout recovery failed: timeout=$timedOut recovery=$recovered" }
    Write-Output 'PASS: unresponsive server times out, reconnects and returns usage'
}
finally {
    $queue.Enqueue('stop')
    Wait-Job $job -Timeout 5 | Out-Null
    Stop-Job $job
    Remove-Job $job -Force
    if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker }
}

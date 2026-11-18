$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null; $parseErrors = $null
$overlay = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'CodexUsageOverlay.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors | Out-String) }
Add-Type -AssemblyName PresentationFramework
foreach ($name in @('Format-WindowLabel', 'Format-ResetTime', 'Get-UiBrush', 'New-UiGradient', 'Show-Usage')) {
    $function = $overlay.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
}
function Update-ResetCreditBadge { param($data) }
$progressFill = [Windows.Controls.Border]::new()
$periodText = [Windows.Controls.TextBlock]::new()
$percentText = [Windows.Controls.TextBlock]::new()
$resetToolTipText = [Windows.Controls.TextBlock]::new()
$script:detailsWindow = $null
$bucket = [pscustomobject]@{
    primary = [pscustomobject]@{ usedPercent = 100; windowDurationMins = 10080; resetsAt = 1800000000 }
    secondary = $null
    credits = [pscustomobject]@{ balance = '62100.9889680000' }
}
$data = [pscustomobject]@{ rateLimits = $bucket }
Show-Usage $data
if ($periodText.Text -ne '剩余额度' -or $percentText.Text -ne '62,101') { throw 'Exhausted subscription should show rounded balance.' }
$bucket.credits.balance = '0'
Show-Usage $data
if ($percentText.Text -ne '0') { throw 'Zero balance should be displayed.' }
$bucket.credits.balance = $null
Show-Usage $data
if ($periodText.Text -ne '每周' -or $percentText.Text -ne '0%') { throw 'Missing balance should retain percentage.' }
$bucket.credits.balance = '62100.9889680000'
$bucket.primary.usedPercent = 30
Show-Usage $data
if ($periodText.Text -ne '每周' -or $percentText.Text -ne '70%') { throw 'Recovered subscription should restore percentage.' }
Write-Output 'PASS: exhausted, zero balance, missing balance, and recovery'

if ($env:GPTBUBBLE_TEST_LIVE -eq '1') {
    $liveData = & (Join-Path $root 'Get-CodexUsage.ps1') | ConvertFrom-Json
    Show-Usage $liveData
    Write-Output "Live display: $($periodText.Text) $($percentText.Text)"
}

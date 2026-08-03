[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-CodexRuntime {
    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $nodeCommand) {
        throw '未找到 node.exe。请先安装 Node.js。'
    }

    $codexCommand = Get-Command codex.cmd -ErrorAction SilentlyContinue
    if (-not $codexCommand) {
        $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    }
    if (-not $codexCommand) {
        throw '未找到 Codex CLI。请先安装并登录 Codex CLI。'
    }

    $npmDirectory = Split-Path -Parent $codexCommand.Source
    $codexScript = Join-Path $npmDirectory 'node_modules\@openai\codex\bin\codex.js'
    if (-not (Test-Path -LiteralPath $codexScript -PathType Leaf)) {
        throw "未找到 Codex CLI 入口：$codexScript"
    }

    [pscustomobject]@{
        NodePath    = $nodeCommand.Source
        CodexScript = $codexScript
    }
}

$runtime = Resolve-CodexRuntime
$processInfo = [System.Diagnostics.ProcessStartInfo]::new()
$processInfo.FileName = $runtime.NodePath
$processInfo.ArgumentList.Add($runtime.CodexScript)
$processInfo.ArgumentList.Add('app-server')
$processInfo.ArgumentList.Add('--listen')
$processInfo.ArgumentList.Add('stdio://')
$processInfo.UseShellExecute = $false
$processInfo.CreateNoWindow = $true
$processInfo.RedirectStandardInput = $true
$processInfo.RedirectStandardOutput = $true
$processInfo.RedirectStandardError = $true
$processInfo.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
$processInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)

$serverProcess = [System.Diagnostics.Process]::new()
$serverProcess.StartInfo = $processInfo

try {
    if (-not $serverProcess.Start()) {
        throw '无法启动 codex app-server。'
    }

    $messages = @(
        @{ method = 'initialize'; id = 1; params = @{ clientInfo = @{ name = 'codex_usage_overlay'; title = 'Codex Usage Overlay'; version = '0.1.0' } } },
        @{ method = 'initialized'; params = @{} },
        @{ method = 'account/rateLimits/read'; id = 2 }
    )

    foreach ($message in $messages) {
        $line = $message | ConvertTo-Json -Depth 8 -Compress
        $serverProcess.StandardInput.WriteLine($line)
    }
    $serverProcess.StandardInput.Flush()

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $readTask = $serverProcess.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait($remaining)) {
            throw "读取剩余用量超时（${TimeoutSeconds} 秒）。"
        }

        $responseLine = $readTask.Result
        if ($null -eq $responseLine) {
            $errorText = $serverProcess.StandardError.ReadToEnd().Trim()
            if ($errorText) {
                throw "codex app-server 已退出：$errorText"
            }
            throw 'codex app-server 在返回剩余用量前已退出。'
        }

        try {
            $response = $responseLine | ConvertFrom-Json -Depth 20
        }
        catch {
            continue
        }

        if ($response.PSObject.Properties.Name -contains 'id' -and $response.id -eq 2) {
            if ($response.PSObject.Properties.Name -contains 'error') {
                if ($response.error.message -match 'authentication required') {
                    throw 'Codex CLI 尚未登录。请先在终端运行 codex login。'
                }
                throw "读取剩余用量失败：$($response.error | ConvertTo-Json -Depth 8 -Compress)"
            }
            $response.result | ConvertTo-Json -Depth 20 -Compress
            return
        }
    }

    throw "读取剩余用量超时（${TimeoutSeconds} 秒）。"
}
finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        $serverProcess.Kill($true)
        $serverProcess.WaitForExit(2000) | Out-Null
    }
    $serverProcess.Dispose()
}

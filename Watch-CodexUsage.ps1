[CmdletBinding()]
param(
    [int]$FallbackSeconds = 60,
    [ValidateRange(1, 120)][int]$RequestTimeoutSeconds = 20,
    [System.Collections.Concurrent.ConcurrentQueue[string]]$CommandQueue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $CommandQueue) {
    $CommandQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
}
$FallbackSeconds = [Math]::Max(10, $FallbackSeconds)

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

function Write-WatcherEvent([string]$kind, [object]$data, [string]$message = '') {
    @{
        kind    = $kind
        data    = $data
        message = $message
    } | ConvertTo-Json -Depth 24 -Compress
}

$lastErrorMessage = ''
$lastErrorAt = [DateTime]::MinValue
$stopRequested = $false

while (-not $stopRequested) {
    $serverProcess = $null
    try {
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
        if (-not $serverProcess.Start()) {
            throw '无法启动 codex app-server。'
        }
        $stderrTask = $serverProcess.StandardError.ReadToEndAsync()

        $sendMessage = {
            param([hashtable]$message)
            $serverProcess.StandardInput.WriteLine(($message | ConvertTo-Json -Depth 8 -Compress))
            $serverProcess.StandardInput.Flush()
        }

        & $sendMessage @{
            method = 'initialize'
            id = 1
            params = @{
                clientInfo = @{
                    name = 'codex_usage_overlay'
                    title = 'Codex Usage Overlay'
                    version = '0.2.0'
                }
            }
        }
        & $sendMessage @{ method = 'initialized'; params = @{} }

        $state = @{
            NextId       = 2
            PendingId    = $null
            PendingSince = [DateTime]::MinValue
            NextFallback = [DateTime]::UtcNow
        }
        $readTask = $null

        while (-not $stopRequested) {
            $command = $null
            while ($CommandQueue.TryDequeue([ref]$command)) {
                if ($command -eq 'stop') {
                    $stopRequested = $true
                    break
                }
                if ($command -eq 'refresh') {
                    $state.NextFallback = [DateTime]::UtcNow
                }
                $command = $null
            }
            if ($stopRequested) { break }

            if ($null -ne $state.PendingId -and
                ([DateTime]::UtcNow - $state.PendingSince).TotalSeconds -ge $RequestTimeoutSeconds) {
                throw "用量请求超过 $RequestTimeoutSeconds 秒未响应，正在重新连接。"
            }

            if ($null -eq $state.PendingId -and [DateTime]::UtcNow -ge $state.NextFallback) {
                $requestId = [int]$state.NextId
                $state.NextId = $requestId + 1
                $state.PendingId = $requestId
                $state.PendingSince = [DateTime]::UtcNow
                $state.NextFallback = [DateTime]::UtcNow.AddSeconds($FallbackSeconds)
                & $sendMessage @{ method = 'account/rateLimits/read'; id = $requestId }
            }

            if (-not $readTask) {
                $readTask = $serverProcess.StandardOutput.ReadLineAsync()
            }
            if (-not $readTask.Wait(250)) { continue }

            $responseLine = $readTask.Result
            $readTask = $null
            if ($null -eq $responseLine) {
                $errorText = if ($stderrTask.IsCompleted) { $stderrTask.Result.Trim() } else { '' }
                if ($errorText) { throw "codex app-server 已退出：$errorText" }
                throw 'codex app-server 连接已关闭。'
            }

            try {
                $response = $responseLine | ConvertFrom-Json -Depth 24
            }
            catch {
                continue
            }

            if ($response.PSObject.Properties.Name -contains 'method' -and
                $response.method -eq 'account/rateLimits/updated') {
                # 通知只携带发生变化的额度；立即补读以取得重置次数等完整数据。
                $state.NextFallback = [DateTime]::UtcNow
                continue
            }

            if ($response.PSObject.Properties.Name -contains 'id' -and
                $null -ne $state.PendingId -and
                [int]$response.id -eq [int]$state.PendingId) {
                $state.PendingId = $null
                $state.NextFallback = [DateTime]::UtcNow.AddSeconds($FallbackSeconds)

                if ($response.PSObject.Properties.Name -contains 'error') {
                    $errorMessage = if ($response.error.message -match 'authentication required') {
                        'Codex CLI 尚未登录。请先在终端运行 codex login。'
                    }
                    else {
                        "读取剩余用量失败：$($response.error | ConvertTo-Json -Depth 8 -Compress)"
                    }
                    Write-WatcherEvent 'error' $null $errorMessage
                    # A request-level error does not close the app-server connection.
                    # Retry quickly instead of leaving the UI stale until the 60s fallback.
                    $state.NextFallback = [DateTime]::UtcNow.AddSeconds(3)
                    continue
                }

                Write-WatcherEvent 'usage' $response.result
                $lastErrorMessage = ''
            }
        }
    }
    catch {
        $message = $_.Exception.Message
        if ($message -ne $lastErrorMessage -or
            ([DateTime]::Now - $lastErrorAt).TotalSeconds -ge 60) {
            Write-WatcherEvent 'error' $null $message
            $lastErrorMessage = $message
            $lastErrorAt = [DateTime]::Now
        }
        if (-not $stopRequested) { Start-Sleep -Seconds 3 }
    }
    finally {
        if ($serverProcess) {
            if (-not $serverProcess.HasExited) {
                $serverProcess.Kill($true)
                $serverProcess.WaitForExit(2000) | Out-Null
            }
            $serverProcess.Dispose()
        }
    }
}

param([Parameter(ValueFromRemainingArguments)]$IgnoredArguments)
$marker = Join-Path $env:TEMP 'gptbubble-timeout-test.marker'
$firstConnection = -not (Test-Path -LiteralPath $marker)
[IO.File]::WriteAllText($marker, 'started')
while ($null -ne ($line = [Console]::ReadLine())) {
    $request = $line | ConvertFrom-Json
    if (-not $firstConnection -and $request.method -eq 'account/rateLimits/read') {
        [Console]::WriteLine((@{ id = $request.id; result = @{ recovered = $true } } | ConvertTo-Json -Compress))
    }
}

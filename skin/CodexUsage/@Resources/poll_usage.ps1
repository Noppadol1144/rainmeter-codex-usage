param([string]$CodexPath, [string]$StatusFile = (Join-Path $PSScriptRoot 'usage_status.txt'))
$ErrorActionPreference = 'Stop'
$mutex = New-Object Threading.Mutex($false, 'Local\CodexUsageWidgetPoll')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit 0 }
$proc = $null
function Send-Rpc($message) {
    $proc.StandardInput.WriteLine(($message | ConvertTo-Json -Compress -Depth 12))
    $proc.StandardInput.Flush()
}
function Read-Rpc($id) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        $pending = $proc.StandardOutput.ReadLineAsync()
        $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $pending.Wait($remaining)) { throw 'Usage request timed out' }
        if ($null -eq $pending.Result) { throw 'Codex app-server closed' }
        $reply = $pending.Result | ConvertFrom-Json
        if ($reply.id -eq $id) {
            if ($reply.error) { throw 'Codex rejected usage request; check Codex sign-in' }
            return $reply.result
        }
    }
    throw 'Usage request timed out'
}
function Format-Reset($epoch) {
    if ($null -eq $epoch) { return 'unknown' }
    $span = [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch) - [DateTimeOffset]::UtcNow
    if ($span.TotalSeconds -le 0) { return 'now' }
    if ($span.TotalDays -ge 1) { return '{0}d {1}h' -f [Math]::Floor($span.TotalDays), $span.Hours }
    return '{0}h {1}m' -f [Math]::Floor($span.TotalHours), $span.Minutes
}
try {
    if (-not $CodexPath) {
        $cmd = Get-Command codex.exe -ErrorAction SilentlyContinue
        if ($cmd) { $CodexPath = $cmd.Source }
    }
    if (-not $CodexPath) {
        $candidate = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'OpenAI/Codex/bin/*/codex.exe') -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($candidate) { $CodexPath = $candidate.FullName }
    }
    if (-not $CodexPath) { throw 'Codex executable not found' }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $CodexPath
    $info.Arguments = 'app-server --listen stdio://'
    $info.WorkingDirectory = $PSScriptRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $info
    [void]$proc.Start()
    $stderr = $proc.StandardError.ReadToEndAsync()
    Send-Rpc @{ id = 1; method = 'initialize'; params = @{ clientInfo = @{ name = 'codex_usage_widget'; title = 'Codex Usage Widget'; version = '1.0.0' } } }
    $null = Read-Rpc 1
    Send-Rpc @{ method = 'initialized' }
    Send-Rpc @{ id = 2; method = 'account/rateLimits/read' }
    $result = Read-Rpc 2
    $limits = $result.rateLimits
    if ($result.rateLimitsByLimitId) {
        $limits = $result.rateLimitsByLimitId.codex
    }
    if (-not $limits) { throw 'Codex quota unavailable' }
    $windows = @($limits.primary, $limits.secondary)
    $five = $windows | Where-Object { $_ -and $_.windowDurationMins -eq 300 } | Select-Object -First 1
    $week = $windows | Where-Object { $_ -and $_.windowDurationMins -eq 10080 } | Select-Object -First 1
    if (-not $five -and -not $week) { throw 'No 5-hour or weekly quota returned' }
    $fiveValue = '--'; $weekValue = '--'
    if ($five -and $null -ne $five.usedPercent) { $fiveValue = [Math]::Round($five.usedPercent) }
    if ($week -and $null -ne $week.usedPercent) { $weekValue = [Math]::Round($week.usedPercent) }
    $lines = @("FIVE_H=$fiveValue", "FIVE_H_RESET=$(Format-Reset $five.resetsAt)",
        "SEVEN_D=$weekValue", "SEVEN_D_RESET=$(Format-Reset $week.resetsAt)",
        "UPDATED=$([DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz', [Globalization.CultureInfo]::InvariantCulture))", 'STATUS=OK', 'NOTE=Percent of quota used')
    $exitCode = 0
} catch {
    $lines = @('FIVE_H=--', 'FIVE_H_RESET=unknown', 'SEVEN_D=--', 'SEVEN_D_RESET=unknown', 'UPDATED=never', 'STATUS=ERROR', 'NOTE=Check Codex sign-in or connection')
    if (Test-Path $StatusFile) {
        $lines = @(Get-Content $StatusFile | ForEach-Object {
            if ($_ -match '^STATUS=') { 'STATUS=ERROR' }
            elseif ($_ -match '^NOTE=') { 'NOTE=Refresh failed; values are from last successful check' }
            else { $_ }
        })
    }
    Write-Warning $_.Exception.Message
    $exitCode = 1
} finally {
    if ($proc) {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        $proc.Dispose()
    }
}
try {
    [IO.File]::WriteAllText("$StatusFile.tmp", ($lines -join "`n"), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath "$StatusFile.tmp" -Destination $StatusFile -Force
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
exit $exitCode

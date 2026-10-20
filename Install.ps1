param([string]$SkinPath)
$ErrorActionPreference = 'Stop'
if (-not $SkinPath) {
    $config = Join-Path $env:APPDATA 'Rainmeter/Rainmeter.ini'
    if (Test-Path $config) {
        $match = Select-String -Path $config -Pattern '^SkinPath=(.+)$' | Select-Object -First 1
        if ($match) { $SkinPath = [Environment]::ExpandEnvironmentVariables($match.Matches[0].Groups[1].Value.Trim()) }
    }
}
if (-not $SkinPath) { throw 'Specify -SkinPath with your Rainmeter Skins directory.' }
$destination = Join-Path $SkinPath 'CodexUsage'
if (Test-Path $destination) {
    Copy-Item $destination "$destination.bak.$(Get-Date -Format yyyyMMddHHmmss)" -Recurse
}
New-Item -ItemType Directory $destination -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'skin/CodexUsage/*') $destination -Recurse -Force
Write-Host 'Installed. Refresh Rainmeter and load CodexUsage.ini.'

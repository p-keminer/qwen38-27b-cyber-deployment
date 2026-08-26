Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stateDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) '.runpod\cybench-supervisor'
$statePath = Join-Path $stateDirectory 'state.json'
$requestPath = Join-Path $stateDirectory 'stop.request.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw 'No Cybench supervisor state exists.'
}
$state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
if (
    [string]::IsNullOrWhiteSpace([string]$state.plan_id) -or
    [string]::IsNullOrWhiteSpace([string]$state.startup_nonce)
) {
    throw 'Supervisor state has no plan-bound stop identity.'
}
$request = [ordered]@{
    request_id = [guid]::NewGuid().ToString('N')
    requested_at_utc = [DateTime]::UtcNow.ToString('o')
    action = 'stop_supervisor_only'
    plan_id = [string]$state.plan_id
    startup_nonce = [string]$state.startup_nonce
}
$temporaryPath = "$requestPath.$PID.tmp"
[IO.File]::WriteAllText($temporaryPath, ($request | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
try {
    $latestState = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
    if (
        -not [string]::Equals([string]$latestState.plan_id, [string]$request.plan_id, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$latestState.startup_nonce, [string]$request.startup_nonce, [StringComparison]::Ordinal)
    ) {
        throw 'Supervisor plan changed while the stop request was being prepared.'
    }
    Move-Item -LiteralPath $temporaryPath -Destination $requestPath -Force
}
finally {
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
}
Write-Host 'Supervisor stop requested. The active Inspect task and RunPod server are not stopped.'

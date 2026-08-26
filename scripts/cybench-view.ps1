param([ValidateRange(1024, 65535)][int]$Port = 7575)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectWindows = Split-Path -Parent $PSScriptRoot
$uri = "http://127.0.0.1:$Port/"
$legacyPidPath = Join-Path $projectWindows '.runpod\inspect-view.pid'

function Invoke-WslViewLifecycle {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('start', 'status')]
        [string]$Action
    )

    # Windows PowerShell 5.1 promotes native stderr to a terminating
    # NativeCommandError when the caller uses ErrorActionPreference=Stop.
    # WSL can emit harmless terminal-size warnings on stderr even when the
    # lifecycle command succeeds, so bind success to the native exit code and
    # retain stderr only as diagnostics for a genuine non-zero exit.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& wsl.exe -d Ubuntu-24.04 --cd $projectWindows -- `
            bash scripts/view-cybench.sh $Action ([string]$Port) 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{
        output = $output
        exit_code = $exitCode
    }
}

$status = Invoke-WslViewLifecycle -Action status
$statusOutput = @($status.output)
$statusExitCode = [int]$status.exit_code
if ($statusExitCode -ne 0) {
    if ($statusExitCode -ne 1) {
        throw "Unable to determine Inspect View ownership. $($statusOutput -join ' ')"
    }
    $start = Invoke-WslViewLifecycle -Action start
    $startOutput = @($start.output)
    if ([int]$start.exit_code -ne 0) {
        throw "Inspect View failed to start. $($startOutput -join ' ')"
    }
}

# Older versions recorded the transient Windows wsl.exe launcher PID. It is
# intentionally discarded only after the WSL-owned lifecycle check succeeded.
Remove-Item -LiteralPath $legacyPidPath -Force -ErrorAction SilentlyContinue

$response = Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 3
if ($response.StatusCode -ne 200 -or $response.Content -notmatch 'Inspect') {
    throw "The project-owned Inspect View endpoint is not valid at $uri"
}

Start-Process $uri
Write-Host "Inspect View: $uri"

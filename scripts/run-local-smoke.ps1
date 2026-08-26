$ErrorActionPreference = 'Stop'

$projectWindows = Split-Path -Parent $PSScriptRoot
wsl.exe -d Ubuntu-24.04 --cd $projectWindows -- bash scripts/run-local-smoke.sh
if ($LASTEXITCODE -ne 0) {
    throw "Local smoke test failed with exit code $LASTEXITCODE."
}

param([ValidateRange(1024, 65535)][int]$Port = 7575)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot

# Windows PowerShell 5.1 promotes native stderr to a terminating
# NativeCommandError under ErrorActionPreference=Stop. WSL may emit a harmless
# terminal-size warning even when the validated lifecycle command succeeds, so
# preserve stderr for diagnostics while binding success to the native exit code.
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $output = @(& wsl.exe -d Ubuntu-24.04 --cd $projectRoot -- `
        bash scripts/view-cybench.sh stop ([string]$Port) 2>&1)
    $exitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($exitCode -ne 0) {
    throw "Inspect View stop failed. $($output -join ' ')"
}
Remove-Item -LiteralPath (Join-Path $projectRoot '.runpod\inspect-view.pid') `
    -Force -ErrorAction SilentlyContinue
$output | ForEach-Object { Write-Host $_ }

param([switch]$SkipImages)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectWindows = Split-Path -Parent $PSScriptRoot
$skip = if ($SkipImages) { 'true' } else { 'false' }
wsl.exe -d Ubuntu-24.04 --cd $projectWindows -- bash scripts/prepare-cybench.sh $skip
if ($LASTEXITCODE -ne 0) {
    throw "Cybench preparation failed with exit code $LASTEXITCODE."
}

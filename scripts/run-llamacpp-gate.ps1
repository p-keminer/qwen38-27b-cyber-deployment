param(
    [string]$ModelId
)

$previousWslEnv = $env:WSLENV
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RunPod.Common.psm1') -Force

try {
    $session = Get-RunPodSession
    $session = Start-RunPodTunnel -Session $session
    Start-RunPodWslTunnel -Session $session
    if ([string]::IsNullOrWhiteSpace($ModelId)) {
        $ModelId = $session.ActiveAlias
    }
    $env:LLAMACPP_API_KEY = Get-RunPodApiKey
    $env:LLAMACPP_BASE_URL = "http://127.0.0.1:$($session.LocalPort)/v1"
    $passThrough = 'LLAMACPP_API_KEY/u:LLAMACPP_BASE_URL/u'
    $env:WSLENV = if ([string]::IsNullOrWhiteSpace($previousWslEnv)) { $passThrough } else { "$previousWslEnv`:$passThrough" }

    $projectWindows = Split-Path -Parent $PSScriptRoot
    wsl.exe -d Ubuntu-24.04 --cd $projectWindows -- bash scripts/run-llamacpp-gate.sh $ModelId
    if ($LASTEXITCODE -ne 0) {
        throw "Remote llama.cpp compatibility gate failed with exit code $LASTEXITCODE."
    }
}
finally {
    $env:WSLENV = $previousWslEnv
    Remove-Item Env:LLAMACPP_API_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:LLAMACPP_BASE_URL -ErrorAction SilentlyContinue
}

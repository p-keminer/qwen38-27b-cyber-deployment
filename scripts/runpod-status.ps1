Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RunPod.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ControlledWeb.Common.psm1') -Force

$session = Get-RunPodSession
Write-Host 'Remote server status:'
$remoteStatus = @(Invoke-RunPodSsh -Session $session -RemoteCommand "bash '$($session.RemoteDir)/runpod/server-control.sh' status")
$remoteStatus | ForEach-Object { Write-Host $_ }
$status = $remoteStatus[0] | ConvertFrom-Json
if (-not $status.running) {
    Write-Host 'The remote model server is stopped. Start it with one of the runpod-*.ps1 model wrappers.'
    return
}
$session = Start-RunPodTunnel -Session $session
Start-RunPodWslTunnel -Session $session
$headers = @{ Authorization = "Bearer $(Get-RunPodApiKey)" }
$models = Invoke-RestMethod -Uri "http://127.0.0.1:$($session.LocalPort)/v1/models" -Headers $headers -TimeoutSec 10
Write-Host "Local tunnel PID: $($session.TunnelPid)"
Write-Host "Local API URL: http://127.0.0.1:$($session.LocalPort)/v1"
Write-Host "WSL API URL: http://127.0.0.1:$($session.LocalPort)/v1 (WSL-local SSH tunnel)"
if (Test-OpenCodeWebProcess -Session $session) {
    Write-Host "OpenCode Web: http://127.0.0.1:$($session.OpenCodePort) (isolated Docker stack)"
    $attestedNetworkMode = Get-ControlledWebRuntimeMode -ExpectedDenyHost ([string]$session.SshHost)
    Write-Host "OpenCode network mode: $attestedNetworkMode (container-attested)"
}
else {
    Write-Host 'OpenCode Web: stopped'
}
$models | ConvertTo-Json -Depth 8

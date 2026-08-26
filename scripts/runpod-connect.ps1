param(
    [switch]$NoBrowser,
    [switch]$ControlledWeb,
    [switch]$Offline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RunPod.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ControlledWeb.Common.psm1') -Force
if ($ControlledWeb -and $Offline) {
    throw 'Choose either -ControlledWeb or -Offline, not both.'
}
$session = Get-RunPodSession
$stackRunning = Test-OpenCodeWebProcess -Session $session
$activeNetworkMode = if ($stackRunning) {
    Get-ControlledWebRuntimeMode -ExpectedDenyHost ([string]$session.SshHost)
}
elseif (
    $session.PSObject.Properties.Name -contains 'OpenCodeNetworkMode' -and
    [string]$session.OpenCodeNetworkMode -eq 'controlled-web-v1'
) {
    'controlled-web-v1'
}
else {
    'offline-v1'
}
$requestedNetworkMode = if ($ControlledWeb) {
    'controlled-web-v1'
}
elseif ($Offline) {
    'offline-v1'
}
else {
    $activeNetworkMode
}
$restartGui = $stackRunning -and $activeNetworkMode -ne $requestedNetworkMode
[void](Start-RunPodTunnel -Session $session)
& (Join-Path $PSScriptRoot 'runpod-gui.ps1') `
    -NoBrowser:$NoBrowser `
    -Restart:$restartGui `
    -ControlledWeb:($requestedNetworkMode -eq 'controlled-web-v1')

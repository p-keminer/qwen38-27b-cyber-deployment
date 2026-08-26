param(
    [Parameter(Mandatory)][ValidateSet('uncensored-q6', 'uncensored-q8', 'uncensored-q4', 'whitehat-q4')][string]$Model,
    [string]$LocalModelRoot,
    [switch]$NoBrowser,
    [switch]$ControlledWeb,
    [switch]$Offline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RunPod.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ControlledWeb.Common.psm1') -Force

$session = Get-RunPodSession
if ($ControlledWeb -and $Offline) {
    throw 'Choose either -ControlledWeb or -Offline, not both.'
}
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
$localOnlySession = (
    $session.PSObject.Properties.Name -contains 'ModelSource' -and
    [string]$session.ModelSource -eq 'local-only'
)
$useLocalArchive = $localOnlySession -or -not [string]::IsNullOrWhiteSpace($LocalModelRoot)
if ($useLocalArchive) {
    if ($Model -notin @('uncensored-q6', 'uncensored-q4', 'whitehat-q4')) {
        throw "No verified external archive profile exists for local-only model '$Model'."
    }
    $seedParameters = @{ Model = $Model }
    if (-not [string]::IsNullOrWhiteSpace($LocalModelRoot)) {
        $seedParameters.BackupRoot = $LocalModelRoot
    }
    & (Join-Path $PSScriptRoot 'runpod-seed-model.ps1') @seedParameters
    $session = Get-RunPodSession
}
$remoteModelSource = if ($useLocalArchive) { 'local-only' } else { 'prefer-local' }
$modelRecord = Get-RunPodModel -Model $Model
Invoke-RunPodSsh `
    -Session $session `
    -RemoteCommand "QWEN_MODEL_SOURCE=$remoteModelSource bash '$($session.RemoteDir)/runpod/server-control.sh' start '$Model'"
$session.ActiveModel = $Model
$session.ActiveAlias = $modelRecord.alias
if ($useLocalArchive) {
    $session | Add-Member -NotePropertyName ModelSource -NotePropertyValue 'local-only' -Force
}
Save-RunPodSession -Session $session
$session = Start-RunPodTunnel -Session $session
Write-Host "Active model: $Model ($($modelRecord.alias))"
Write-Host "API URL: http://127.0.0.1:$($session.LocalPort)/v1"
& (Join-Path $PSScriptRoot 'runpod-gui.ps1') `
    -Restart `
    -NoBrowser:$NoBrowser `
    -ControlledWeb:($requestedNetworkMode -eq 'controlled-web-v1')

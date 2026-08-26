param([switch]$RemoteServer)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RunPod.Common.psm1') -Force

$session = Get-RunPodSessionForLocalCleanup
$qualifiedSession = $false
$qualificationFailure = $null
if ($null -ne $session) {
    try {
        Assert-RunPodQualifiedSession -Session $session
        $qualifiedSession = $true
    }
    catch {
        $qualificationFailure = $_.Exception.Message
    }
}
Stop-OpenCodeWeb -Session $session

if (-not $qualifiedSession) {
    Write-Host 'The ownership-checked local OpenCode containers and networks were stopped.'
    $reason = if ($null -eq $session) {
        'No readable RunPod session is available.'
    }
    else {
        "The RunPod session is not qualified: $qualificationFailure"
    }
    if ($RemoteServer) {
        throw "$reason Remote-server and tunnel actions were refused."
    }
    Write-Warning "$reason Local tunnel actions were skipped fail-closed."
    return
}

Stop-RunPodWslTunnel -Session $session
if ($RemoteServer) {
    Invoke-RunPodSsh -Session $session -RemoteCommand "bash '$($session.RemoteDir)/runpod/server-control.sh' stop"
}
Stop-RunPodTunnel -Session $session
Write-Host 'The isolated OpenCode stack and the local SSH tunnel were stopped.'
if (-not $RemoteServer) {
    Write-Host 'The remote model server and the billed RunPod are still running.'
}

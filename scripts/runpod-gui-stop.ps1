param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RunPod.Common.psm1') -Force

$session = Get-RunPodSessionForLocalCleanup
Stop-OpenCodeWeb -Session $session
Write-Host 'The isolated OpenCode stack was stopped.'

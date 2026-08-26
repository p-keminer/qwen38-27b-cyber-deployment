param(
    [Parameter(Mandatory)]
    [ValidateSet('uncensored-q6', 'uncensored-q4', 'whitehat-q4')]
    [string]$Model,
    [string]$BackupRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RunPod.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ModelBackup.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RemoteModelActivation.Common.psm1') -Force

$projectRoot = Get-QwenProjectRoot
$session = Get-RunPodSession
Assert-RunPodQualifiedSession -Session $session
if (
    $session.PSObject.Properties.Name -notcontains 'ModelSourcePolicy' -or
    [string]$session.ModelSourcePolicy -ne
    'content-addressed-hub-or-verified-local-v1'
) {
    throw 'The qualified session predates the approved content-addressed model source policy.'
}

$resolvedBackupRoot = Resolve-QwenModelBackupRoot `
    -BackupRoot $BackupRoot `
    -ProjectRoot $projectRoot `
    -Required
$backup = Assert-QwenModelBackup `
    -ProjectRoot $projectRoot `
    -BackupRoot $resolvedBackupRoot `
    -Model $Model

$remoteDir = [string]$session.RemoteDir
$remoteManifestOutput = @(
    Invoke-RunPodSshBounded `
        -Session $session `
        -RemoteCommand "sha256sum '$remoteDir/config/models.json' | awk '{print `$1}'" `
        -TimeoutSeconds 60
)
if (
    $remoteManifestOutput.Count -ne 1 -or
    -not [string]::Equals(
        [string]$remoteManifestOutput[0],
        [string]$backup.ManifestSha256,
        [StringComparison]::Ordinal
    )
) {
    throw 'Remote model manifest does not match the verified local archive.'
}

$activation = Invoke-QwenRemoteModelActivation `
    -Session $session `
    -ProjectRoot $projectRoot `
    -RemoteDir $remoteDir `
    -Model $Model `
    -Backup $backup

$seeded = @()
if ($session.PSObject.Properties.Name -contains 'LocallySeededModels') {
    $seeded = @($session.LocallySeededModels)
}
$seeded = @($seeded + $Model | Sort-Object -Unique)
$session | Add-Member -NotePropertyName LocallySeededModels -NotePropertyValue $seeded -Force
$session | Add-Member -NotePropertyName LocalModelManifestSha256 -NotePropertyValue ([string]$backup.ManifestSha256) -Force
Save-RunPodSession -Session $session

[pscustomobject]@{
    operation = 'runpod.seed_model'
    model_id = $Model
    uploaded = [bool]$activation.Uploaded
    source = 'verified_local_archive'
    manifest_sha256 = [string]$backup.ManifestSha256
    remote_verified = $true
} | ConvertTo-Json -Depth 6 -Compress

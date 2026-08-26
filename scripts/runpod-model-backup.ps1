param(
    [ValidateSet('uncensored-q6', 'uncensored-q4', 'whitehat-q4', 'uncensored-q8')]
    [string[]]$Model = @('uncensored-q6', 'uncensored-q4'),
    [string]$BackupRoot,
    [switch]$VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'ModelBackup.Common.psm1') -Force
$expectedVolumeLabel = 'BACKUP_WIN'
$defaultFolderName = 'qwen38-27b-model-backup'

if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $volumes = @(Get-Volume -FileSystemLabel $expectedVolumeLabel -ErrorAction SilentlyContinue)
    if ($volumes.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$volumes[0].DriveLetter)) {
        throw "Expected exactly one mounted volume labeled $expectedVolumeLabel."
    }
    if ([string]$volumes[0].HealthStatus -ne 'Healthy') {
        throw "Backup volume $expectedVolumeLabel is not healthy."
    }
    $BackupRoot = "$($volumes[0].DriveLetter):\$defaultFolderName"
}

$fullBackupRoot = ConvertTo-QwenCanonicalWindowsPath -Path $BackupRoot
$fullProjectRoot = ConvertTo-QwenCanonicalWindowsPath -Path $projectRoot
if (Test-QwenPathIsSameOrDescendant -Path $fullBackupRoot -Parent $fullProjectRoot) {
    throw 'The model vault must be outside the agent-writable project root.'
}
if ($fullBackupRoot -notmatch '^(?<drive>[A-Za-z]):\\(?<tail>.*)$') {
    throw 'The backup root must be an absolute Windows drive path.'
}

$driveLetter = $Matches.drive.ToUpperInvariant()
$tail = $Matches.tail.Replace('\', '/')
[void](Assert-QwenPathHasNoReparsePoint `
    -Path $fullBackupRoot `
    -Description 'backup root')
$volume = Assert-QwenModelBackupVolume -CanonicalPath $fullBackupRoot
[IO.Directory]::CreateDirectory($fullBackupRoot) | Out-Null
[void](Assert-QwenPathHasNoReparsePoint `
    -Path $fullBackupRoot `
    -Description 'backup root')

$mountPath = "/mnt/$($driveLetter.ToLowerInvariant())"
& wsl.exe -d Ubuntu-24.04 -u root -- mkdir -p $mountPath
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to prepare the WSL backup-drive mount point.'
}
& wsl.exe -d Ubuntu-24.04 -u root -- mountpoint -q $mountPath
if ($LASTEXITCODE -ne 0) {
    & wsl.exe -d Ubuntu-24.04 -u root -- mount -t drvfs "$driveLetter`:" $mountPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to mount $driveLetter`: in WSL."
    }
}
$mountedSource = (& wsl.exe -d Ubuntu-24.04 -u root -- findmnt -n -o SOURCE --target $mountPath).Trim()
$normalizedMountedSource = $mountedSource.TrimEnd('\')
if (
    $LASTEXITCODE -ne 0 -or
    -not [string]::Equals(
        $normalizedMountedSource,
        "$driveLetter`:",
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "WSL mount $mountPath does not resolve to the requested Windows drive $driveLetter`:"
}

$wslBackupRoot = if ([string]::IsNullOrEmpty($tail)) { $mountPath } else { "$mountPath/$tail" }
& wsl.exe -d Ubuntu-24.04 -u root -- mkdir -p $wslBackupRoot
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to create the WSL backup directory.'
}
if (-not [string]::IsNullOrEmpty($tail)) {
    & wsl.exe -d Ubuntu-24.04 -u root -- chown qwen-eval:qwen-eval $wslBackupRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to make the backup directory writable by the local runtime user.'
    }
}

$manifestPath = Join-Path $projectRoot 'config\models.json'
$wslProjectRoot = (& wsl.exe -d Ubuntu-24.04 -u qwen-eval --exec wslpath -a -u -- $projectRoot).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($wslProjectRoot)) {
    throw 'Failed to map the project path into WSL.'
}
$wslManifest = "$wslProjectRoot/config/models.json"
$wslScript = "$wslProjectRoot/scripts/model_backup.py"
$pythonArguments = @(
    $wslScript,
    '--manifest', $wslManifest,
    '--backup-root', $wslBackupRoot
)
foreach ($modelId in $Model) {
    $pythonArguments += @('--model', $modelId)
}
if ($VerifyOnly) {
    $pythonArguments += '--verify-only'
}

$wslEnvironment = @(
    "HF_HOME=$wslBackupRoot/.hf-home",
    "HF_HUB_OFFLINE=$(if ($VerifyOnly) { '1' } else { '0' })"
)
if ($VerifyOnly) {
    # This branch intentionally uses only Ubuntu's stdlib Python. It neither
    # resolves a uv environment nor imports huggingface_hub.
    $wslEnvironment += '/usr/bin/python3'
    $wslEnvironment += $pythonArguments
}
else {
    $wslEnvironment += '/home/qwen-eval/.local/bin/uv'
    $wslEnvironment += @('run', '--with', 'huggingface-hub==1.28.0', 'python')
    $wslEnvironment += $pythonArguments
}
& wsl.exe -d Ubuntu-24.04 -u qwen-eval -- env @wslEnvironment
if ($LASTEXITCODE -ne 0) {
    throw "Model backup command failed with exit code $LASTEXITCODE."
}

Write-Host "Verified model vault: $fullBackupRoot"

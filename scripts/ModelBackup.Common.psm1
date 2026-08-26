Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-QwenCanonicalWindowsPath {
    param([Parameter(Mandatory)][string]$Path)

    if (
        [string]::IsNullOrWhiteSpace($Path) -or
        $Path -notmatch '^[A-Za-z]:[\\/]'
    ) {
        throw 'The model vault path must be an absolute Windows drive path.'
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ($pathRoot -notmatch '^[A-Za-z]:\\$') {
        throw 'The model vault path must use a local Windows drive letter.'
    }
    if ([string]::Equals($fullPath, $pathRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $pathRoot
    }
    return $fullPath.TrimEnd('\')
}

function Test-QwenPathIsSameOrDescendant {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent
    )

    $canonicalPath = ConvertTo-QwenCanonicalWindowsPath -Path $Path
    $canonicalParent = ConvertTo-QwenCanonicalWindowsPath -Path $Parent
    if ([string]::Equals($canonicalPath, $canonicalParent, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $parentPrefix = if ($canonicalParent.EndsWith('\')) {
        $canonicalParent
    }
    else {
        $canonicalParent + '\'
    }
    return $canonicalPath.StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-QwenPathHasNoReparsePoint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    $canonicalPath = ConvertTo-QwenCanonicalWindowsPath -Path $Path
    $pathRoot = [IO.Path]::GetPathRoot($canonicalPath)
    $components = @($pathRoot)
    $relative = $canonicalPath.Substring($pathRoot.Length).TrimEnd('\')
    if (-not [string]::IsNullOrEmpty($relative)) {
        $current = $pathRoot
        foreach ($segment in $relative.Split('\')) {
            if ([string]::IsNullOrEmpty($segment)) {
                continue
            }
            $current = Join-Path $current $segment
            $components += $current
        }
    }
    foreach ($component in $components) {
        if (-not (Test-Path -LiteralPath $component)) {
            continue
        }
        $item = Get-Item -LiteralPath $component -Force -ErrorAction Stop
        if (
            ([IO.FileAttributes]$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        ) {
            throw "Unsafe reparse point in $Description`: $component"
        }
    }
    return $canonicalPath
}

function Assert-QwenBackupPathContained {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$Description
    )

    $canonicalRoot = Assert-QwenPathHasNoReparsePoint `
        -Path $BackupRoot `
        -Description 'backup root'
    $canonicalPath = ConvertTo-QwenCanonicalWindowsPath -Path $Path
    if (-not (Test-QwenPathIsSameOrDescendant -Path $canonicalPath -Parent $canonicalRoot)) {
        throw "$Description escapes the model backup root: $canonicalPath"
    }
    [void](Assert-QwenPathHasNoReparsePoint -Path $canonicalPath -Description $Description)
    return $canonicalPath
}

function Assert-QwenBackupRegularFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$Description
    )

    $canonicalPath = Assert-QwenBackupPathContained `
        -Path $Path `
        -BackupRoot $BackupRoot `
        -Description $Description
    if (-not (Test-Path -LiteralPath $canonicalPath -PathType Leaf)) {
        throw "$Description is missing or is not a regular file: $canonicalPath"
    }
    $item = Get-Item -LiteralPath $canonicalPath -Force -ErrorAction Stop
    if (
        ([IO.FileAttributes]$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw "Unsafe reparse point in $Description`: $canonicalPath"
    }
    return $canonicalPath
}

function Test-QwenJsonNonNegativeInteger {
    param([AllowNull()]$Value)

    if ($null -eq $Value -or $Value -is [bool]) {
        return $false
    }
    if (
        $Value -isnot [byte] -and
        $Value -isnot [sbyte] -and
        $Value -isnot [int16] -and
        $Value -isnot [uint16] -and
        $Value -isnot [int32] -and
        $Value -isnot [uint32] -and
        $Value -isnot [int64] -and
        $Value -isnot [uint64]
    ) {
        return $false
    }
    return (
        [decimal]$Value -ge 0 -and
        [decimal]$Value -le [decimal][int64]::MaxValue
    )
}

function Assert-QwenModelBackupVolume {
    param([Parameter(Mandatory)][string]$CanonicalPath)

    $pathRoot = [IO.Path]::GetPathRoot($CanonicalPath)
    $driveLetter = $pathRoot.Substring(0, 1).ToUpperInvariant()
    $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
    if ([string]$volume.HealthStatus -ne 'Healthy') {
        throw "Backup drive $driveLetter`: is not healthy."
    }
    $fileSystem = [string]$volume.FileSystem
    if ($fileSystem -in @('FAT', 'FAT32')) {
        throw "Backup drive $driveLetter`: uses $fileSystem, which cannot store the pinned GGUF files."
    }
    if ($fileSystem -notin @('exFAT', 'NTFS', 'ReFS')) {
        throw "Unsupported model-backup filesystem on $driveLetter`: $fileSystem"
    }
    return $volume
}

function Resolve-QwenModelBackupRoot {
    param(
        [string]$BackupRoot,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$Required
    )

    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $volumes = @(Get-Volume -FileSystemLabel 'BACKUP_WIN' -ErrorAction SilentlyContinue)
        if ($volumes.Count -eq 0) {
            if ($Required) {
                throw 'The required BACKUP_WIN model vault is not mounted.'
            }
            return $null
        }
        if ($volumes.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$volumes[0].DriveLetter)) {
            throw 'Expected exactly one mounted BACKUP_WIN volume.'
        }
        if ([string]$volumes[0].HealthStatus -ne 'Healthy') {
            throw 'The BACKUP_WIN volume is not healthy.'
        }
        $BackupRoot = "$($volumes[0].DriveLetter):\qwen38-27b-model-backup"
    }

    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        if ($Required) {
            throw "Required model backup root is missing: $BackupRoot"
        }
        return $null
    }
    [void](Assert-QwenPathHasNoReparsePoint `
        -Path (ConvertTo-QwenCanonicalWindowsPath -Path $BackupRoot) `
        -Description 'backup root')
    $resolvedRoot = ConvertTo-QwenCanonicalWindowsPath `
        -Path (Resolve-Path -LiteralPath $BackupRoot -ErrorAction Stop).Path
    $resolvedProject = ConvertTo-QwenCanonicalWindowsPath `
        -Path (Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).Path
    if (Test-QwenPathIsSameOrDescendant -Path $resolvedRoot -Parent $resolvedProject) {
        throw 'The model vault must remain outside the agent-writable project root.'
    }
    [void](Assert-QwenPathHasNoReparsePoint -Path $resolvedRoot -Description 'backup root')
    [void](Assert-QwenModelBackupVolume -CanonicalPath $resolvedRoot)
    return $resolvedRoot
}

function Get-QwenModelBackupRecord {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidateSet('uncensored-q6', 'uncensored-q4', 'whitehat-q4', 'uncensored-q8')][string]$Model
    )

    $manifestPath = Join-Path $ProjectRoot 'config\models.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    $matches = @($manifest.models | Where-Object { [string]$_.id -eq $Model })
    if ($matches.Count -ne 1) {
        throw "Model id must occur exactly once in the manifest: $Model"
    }
    return [pscustomobject]@{
        ManifestPath = $manifestPath
        ManifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Model = $matches[0]
    }
}

function Assert-QwenArtifactContractList {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][object[]]$Contracts,
        [Parameter(Mandatory)][string]$Description
    )

    $items = @($Value)
    if ($items.Count -ne $Contracts.Count) {
        throw "$Description must contain exactly $($Contracts.Count) pinned artifacts."
    }
    for ($index = 0; $index -lt $Contracts.Count; $index++) {
        $item = $items[$index]
        $contract = $Contracts[$index]
        foreach ($property in @('role', 'filename', 'size_bytes', 'sha256')) {
            if ($item.PSObject.Properties.Name -notcontains $property) {
                throw "$Description artifact $index lacks '$property'."
            }
        }
        if (
            [string]$item.role -ne [string]$contract.Role -or
            [string]$item.filename -ne [string]$contract.Filename -or
            [int64]$item.size_bytes -ne [int64]$contract.Size -or
            -not [string]::Equals(
                [string]$item.sha256,
                [string]$contract.Sha256,
                [StringComparison]::Ordinal
            )
        ) {
            throw "$Description artifact $index does not match the pinned manifest."
        }
    }
}

function Test-QwenReadyModelSourceBinding {
    param(
        [Parameter(Mandatory)]$ExistingState,
        [Parameter(Mandatory)]$ReadySession,
        [Parameter(Mandatory)][ValidateSet('hub', 'local-only')][string]$ExpectedModelSource,
        [Parameter(Mandatory)][string]$ExpectedModelSourcePolicy,
        [AllowNull()][string]$ExpectedBackupManifestSha256,
        [Parameter(Mandatory)][string]$RequiredModel
    )

    foreach ($binding in @(
        [pscustomobject]@{ Value = $ExistingState; Property = 'model_source'; Expected = $ExpectedModelSource },
        [pscustomobject]@{ Value = $ExistingState; Property = 'model_source_policy'; Expected = $ExpectedModelSourcePolicy },
        [pscustomobject]@{ Value = $ExistingState; Property = 'model_id'; Expected = $RequiredModel },
        [pscustomobject]@{ Value = $ReadySession; Property = 'ModelSource'; Expected = $ExpectedModelSource },
        [pscustomobject]@{ Value = $ReadySession; Property = 'ModelSourcePolicy'; Expected = $ExpectedModelSourcePolicy },
        [pscustomobject]@{ Value = $ReadySession; Property = 'ActiveModel'; Expected = $RequiredModel }
    )) {
        if (
            $binding.Value.PSObject.Properties.Name -notcontains $binding.Property -or
            -not [string]::Equals(
                [string]$binding.Value.($binding.Property),
                [string]$binding.Expected,
                [StringComparison]::Ordinal
            )
        ) {
            return $false
        }
    }

    $stateBackupSha256 = if (
        $ExistingState.PSObject.Properties.Name -contains 'model_backup_manifest_sha256'
    ) { [string]$ExistingState.model_backup_manifest_sha256 } else { '' }
    $sessionBackupSha256 = if (
        $ReadySession.PSObject.Properties.Name -contains 'LocalModelManifestSha256'
    ) { [string]$ReadySession.LocalModelManifestSha256 } else { '' }
    if ($ExpectedModelSource -eq 'hub') {
        return (
            [string]::IsNullOrEmpty($stateBackupSha256) -and
            [string]::IsNullOrEmpty($sessionBackupSha256)
        )
    }
    if (
        [string]::IsNullOrWhiteSpace($ExpectedBackupManifestSha256) -or
        -not [string]::Equals($stateBackupSha256, $ExpectedBackupManifestSha256, [StringComparison]::Ordinal) -or
        -not [string]::Equals($sessionBackupSha256, $ExpectedBackupManifestSha256, [StringComparison]::Ordinal) -or
        $ReadySession.PSObject.Properties.Name -notcontains 'LocallySeededModels'
    ) {
        return $false
    }
    return @($ReadySession.LocallySeededModels) -contains $RequiredModel
}

function Assert-QwenModelBackup {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][ValidateSet('uncensored-q6', 'uncensored-q4', 'whitehat-q4', 'uncensored-q8')][string]$Model
    )

    $resolvedRoot = Resolve-QwenModelBackupRoot `
        -BackupRoot $BackupRoot `
        -ProjectRoot $ProjectRoot `
        -Required
    $record = Get-QwenModelBackupRecord -ProjectRoot $ProjectRoot -Model $Model
    $modelDirectory = Assert-QwenBackupPathContained `
        -Path (Join-Path $resolvedRoot $Model) `
        -BackupRoot $resolvedRoot `
        -Description 'model directory'
    if (-not (Test-Path -LiteralPath $modelDirectory -PathType Container)) {
        throw "Model backup directory is missing: $modelDirectory"
    }
    $manifestSnapshotPath = Assert-QwenBackupRegularFile `
        -Path (Join-Path $resolvedRoot "config\models.$($record.ManifestSha256).json") `
        -BackupRoot $resolvedRoot `
        -Description 'versioned model manifest snapshot'
    $manifestSnapshotSha256 = (Get-FileHash `
        -LiteralPath $manifestSnapshotPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not [string]::Equals(
        $manifestSnapshotSha256,
        $record.ManifestSha256,
        [StringComparison]::Ordinal
    )) {
        throw 'Versioned model manifest snapshot failed SHA-256 verification.'
    }
    $contracts = @(
        [pscustomobject]@{
            Role = 'model'
            Filename = [string]$record.Model.filename
            Size = [int64]$record.Model.expected_size_bytes
            Sha256 = [string]$record.Model.sha256
        },
        [pscustomobject]@{
            Role = 'vision_projector'
            Filename = [string]$record.Model.vision_projector.filename
            Size = [int64]$record.Model.vision_projector.expected_size_bytes
            Sha256 = [string]$record.Model.vision_projector.sha256
        }
    )
    $completePath = Join-Path $modelDirectory '.complete.json'
    $completePath = Assert-QwenBackupRegularFile `
        -Path $completePath `
        -BackupRoot $resolvedRoot `
        -Description 'model backup completion marker'
    $complete = Get-Content -LiteralPath $completePath -Raw -Encoding utf8 | ConvertFrom-Json
    if (
        [int]$complete.schema_version -ne 3 -or
        $complete.complete -isnot [bool] -or
        -not $complete.complete -or
        [string]$complete.model_id -ne $Model -or
        [string]$complete.repo_id -ne [string]$record.Model.repo_id -or
        [string]$complete.revision -ne [string]$record.Model.revision -or
        [string]$complete.manifest_sha256 -ne $record.ManifestSha256
    ) {
        throw "Model backup completion marker does not match the pinned manifest: $Model"
    }
    $acquisitionRelativePath = [string]$complete.acquisition_relative_path
    $verificationRelativePath = [string]$complete.verification_relative_path
    if (
        $acquisitionRelativePath -ne 'provenance/acquisition.json' -or
        $verificationRelativePath -ne 'verification.json' -or
        [string]$complete.acquisition_sha256 -notmatch '^[0-9a-f]{64}$' -or
        [string]$complete.verification_sha256 -notmatch '^[0-9a-f]{64}$'
    ) {
        throw "Model backup completion marker has unsafe provenance references: $Model"
    }
    $acquisitionPath = Join-Path $modelDirectory $acquisitionRelativePath.Replace('/', '\')
    $verificationPath = Join-Path $modelDirectory $verificationRelativePath
    foreach ($metadataContract in @(
        [pscustomobject]@{
            Name = 'acquisition'
            Path = $acquisitionPath
            Sha256 = [string]$complete.acquisition_sha256
        },
        [pscustomobject]@{
            Name = 'verification'
            Path = $verificationPath
            Sha256 = [string]$complete.verification_sha256
        }
    )) {
        $safeMetadataPath = Assert-QwenBackupRegularFile `
            -Path $metadataContract.Path `
            -BackupRoot $resolvedRoot `
            -Description "model backup $($metadataContract.Name) metadata"
        $metadataSha256 = (Get-FileHash `
            -LiteralPath $safeMetadataPath `
            -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not [string]::Equals(
            $metadataSha256,
            $metadataContract.Sha256,
            [StringComparison]::Ordinal
        )) {
            throw "Model backup $($metadataContract.Name) metadata failed SHA-256 verification: $Model"
        }
    }
    $acquisition = Get-Content -LiteralPath $acquisitionPath -Raw -Encoding utf8 | ConvertFrom-Json
    $verification = Get-Content -LiteralPath $verificationPath -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($metadataContract in @(
        [pscustomobject]@{ Value = $acquisition; Property = 'artifacts'; Description = 'Acquisition metadata' },
        [pscustomobject]@{ Value = $verification; Property = 'artifacts'; Description = 'Verification metadata' },
        [pscustomobject]@{ Value = $complete; Property = 'artifacts'; Description = 'Completion marker' }
    )) {
        if ($metadataContract.Value.PSObject.Properties.Name -notcontains $metadataContract.Property) {
            throw "$($metadataContract.Description) lacks the pinned artifact contract."
        }
        Assert-QwenArtifactContractList `
            -Value $metadataContract.Value.($metadataContract.Property) `
            -Contracts $contracts `
            -Description $metadataContract.Description
    }
    if (
        [int]$acquisition.schema_version -ne 1 -or
        [string]$acquisition.model_id -ne $Model -or
        [string]$acquisition.repo_id -ne [string]$record.Model.repo_id -or
        [string]$acquisition.requested_revision -ne [string]$record.Model.revision -or
        [string]$acquisition.resolved_revision -ne [string]$record.Model.revision -or
        [int]$verification.schema_version -ne 1 -or
        [string]$verification.model_id -ne $Model -or
        [string]$verification.repo_id -ne [string]$record.Model.repo_id -or
        [string]$verification.revision -ne [string]$record.Model.revision -or
        [string]$verification.manifest_sha256 -ne $record.ManifestSha256 -or
        [string]$verification.acquisition_relative_path -ne 'provenance/acquisition.json' -or
        [string]$verification.acquisition_sha256 -ne [string]$complete.acquisition_sha256
    ) {
        throw "Model backup provenance does not match the pinned manifest: $Model"
    }
    if (
        $acquisition.PSObject.Properties.Name -notcontains 'provenance_files' -or
        $null -eq $acquisition.provenance_files -or
        $acquisition.provenance_files -isnot [System.Array]
    ) {
        throw "Immutable acquisition metadata lacks provenance_files: $Model"
    }
    $seenProvenancePaths = @{}
    foreach ($provenanceFile in @($acquisition.provenance_files)) {
        foreach ($property in @('filename', 'relative_path', 'size_bytes', 'sha256')) {
            if ($provenanceFile.PSObject.Properties.Name -notcontains $property) {
                throw "Immutable provenance file contract lacks '$property': $Model"
            }
        }
        $provenanceFilename = [string]$provenanceFile.filename
        $provenanceRelativePath = [string]$provenanceFile.relative_path
        if (
            $provenanceFilename -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
            $provenanceRelativePath -ne "provenance/$provenanceFilename" -or
            -not (Test-QwenJsonNonNegativeInteger -Value $provenanceFile.size_bytes) -or
            [string]$provenanceFile.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $seenProvenancePaths.ContainsKey($provenanceRelativePath)
        ) {
            throw "Invalid immutable provenance file contract: $Model"
        }
        $seenProvenancePaths[$provenanceRelativePath] = $true
        $provenancePath = Assert-QwenBackupRegularFile `
            -Path (Join-Path $modelDirectory $provenanceRelativePath.Replace('/', '\')) `
            -BackupRoot $resolvedRoot `
            -Description 'immutable provenance file'
        $provenanceItem = Get-Item -LiteralPath $provenancePath
        if ([int64]$provenanceItem.Length -ne [int64]$provenanceFile.size_bytes) {
            throw "Immutable provenance file has the wrong size: $provenanceRelativePath"
        }
        $provenanceSha256 = (Get-FileHash -LiteralPath $provenancePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not [string]::Equals(
            $provenanceSha256,
            [string]$provenanceFile.sha256,
            [StringComparison]::Ordinal
        )) {
            throw "Immutable provenance file failed SHA-256 verification: $provenanceRelativePath"
        }
    }
    $verified = @()
    foreach ($contract in $contracts) {
        if ($contract.Filename -notmatch '^[A-Za-z0-9._-]+$') {
            throw "Unsafe model artifact filename in manifest: $($contract.Filename)"
        }
        $path = Assert-QwenBackupRegularFile `
            -Path (Join-Path $modelDirectory $contract.Filename) `
            -BackupRoot $resolvedRoot `
            -Description 'model backup artifact'
        $file = Get-Item -LiteralPath $path
        if ([int64]$file.Length -ne $contract.Size) {
            throw "Model backup artifact has the wrong size: $($contract.Filename)"
        }
        $actualSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not [string]::Equals($actualSha256, $contract.Sha256, [StringComparison]::Ordinal)) {
            throw "Model backup artifact failed SHA-256 verification: $($contract.Filename)"
        }
        $verified += [pscustomobject]@{
            Role = $contract.Role
            Filename = $contract.Filename
            Path = $path
            Size = $contract.Size
            Sha256 = $actualSha256
        }
    }
    return [pscustomobject]@{
        Root = $resolvedRoot
        ModelId = $Model
        ModelDirectory = $modelDirectory
        ManifestSha256 = $record.ManifestSha256
        Revision = [string]$record.Model.revision
        Artifacts = $verified
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-QwenCanonicalWindowsPath',
    'Test-QwenPathIsSameOrDescendant',
    'Assert-QwenPathHasNoReparsePoint',
    'Assert-QwenModelBackupVolume',
    'Resolve-QwenModelBackupRoot',
    'Get-QwenModelBackupRecord',
    'Assert-QwenModelBackup',
    'Test-QwenReadyModelSourceBinding'
)

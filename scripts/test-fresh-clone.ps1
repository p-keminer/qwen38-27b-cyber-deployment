[CmdletBinding()]
param(
    [switch]$SkipUnitTests,
    [switch]$UseHostTools
)

$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temporaryRoot = $temporaryRoot.TrimEnd(@(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)) + [IO.Path]::DirectorySeparatorChar
$cloneLeaf = 'qwen-eval-fresh-clone-' + [guid]::NewGuid().ToString('N')
$cloneRoot = [IO.Path]::GetFullPath((Join-Path $temporaryRoot $cloneLeaf))

if (-not $cloneRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
    -not ([IO.Path]::GetFileName($cloneRoot)).StartsWith('qwen-eval-fresh-clone-', [StringComparison]::Ordinal)) {
    throw "Unsafe temporary clone path: ${cloneRoot}"
}

Push-Location $sourceRoot
try {
    & git rev-parse --verify HEAD 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Fresh-clone gate requires at least one local commit.'
    }
    if (@(& git status --porcelain --untracked-files=all).Count -ne 0) {
        throw 'Fresh-clone gate requires a clean source worktree.'
    }

    & git clone --local --no-hardlinks --no-tags -- $sourceRoot $cloneRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'Local clone failed.'
    }

    Push-Location $cloneRoot
    try {
        $tracked = @(& git ls-files)
        $forbidden = @(
            '.env', '.venv/', '.runpod/', '.opencode/',
            'artifacts/logs/', 'artifacts/mock-api/', 'artifacts/benchmarks/',
            'artifacts/reviews/', 'artifacts/recovered-documentation/',
            'artifacts/acceptance/',
            'results/runs/', 'models/', 'runtime/', 'state/', 'cache/', 'logs/'
        )
        $allowedPlaceholders = @(
            'artifacts/logs/.gitkeep',
            'artifacts/mock-api/.gitkeep',
            'artifacts/benchmarks/.gitkeep',
            'artifacts/reviews/.gitkeep',
            'results/runs/.gitkeep'
        )
        foreach ($path in $tracked) {
            $normalized = $path -replace '\\', '/'
            if ($allowedPlaceholders -contains $normalized) {
                continue
            }
            $leafName = [IO.Path]::GetFileName($normalized)
            if (
                ($leafName -eq '.env' -or $leafName.StartsWith('.env.', [StringComparison]::Ordinal)) -and
                -not [string]::Equals($normalized, '.env.example', [StringComparison]::Ordinal)
            ) {
                throw "Environment file must not be tracked: ${normalized}"
            }
            if ($normalized -match '(^|/)__pycache__(/|$)' -or $normalized -match '\.pyc$') {
                throw "Generated Python file is tracked: ${normalized}"
            }
            foreach ($prefix in $forbidden) {
                $matchesForbiddenPath = if ($prefix.EndsWith('/', [StringComparison]::Ordinal)) {
                    $normalized.StartsWith($prefix, [StringComparison]::Ordinal)
                }
                else {
                    [string]::Equals($normalized, $prefix, [StringComparison]::Ordinal)
                }
                if ($matchesForbiddenPath) {
                    throw "Forbidden runtime path is tracked: ${normalized}"
                }
            }
        }

        $manifest = Get-Content -Raw -LiteralPath 'config/runpod-a100-pcie-deployment.json' | ConvertFrom-Json
        $modelHash = (Get-FileHash -LiteralPath 'config/models.json' -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($modelHash -ne [string]$manifest.workload.model_manifest_sha256) {
            throw "Model manifest byte hash mismatch after clone: ${modelHash}"
        }

        foreach ($path in @($tracked | Where-Object { $_ -like '*.sh' })) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $cloneRoot $path))
            for ($index = 0; $index -lt ($bytes.Length - 1); $index++) {
                if ($bytes[$index] -eq 13 -and $bytes[$index + 1] -eq 10) {
                    throw "CRLF found in tracked shell script: ${path}"
                }
            }
        }
        foreach ($entry in @(& git ls-files -s -- '*.sh')) {
            if (-not $entry.StartsWith('100755 ', [StringComparison]::Ordinal)) {
                throw "Shell script is not executable in Git index: ${entry}"
            }
        }

        $blocked = {
            throw "Cloud/external command was called during provisioning dry-run: $($MyInvocation.MyCommand.Name)"
        }
        $blockedNames = @(
            'Invoke-RestMethod',
            'ssh.exe', 'scp.exe', 'docker.exe', 'wsl.exe', 'curl.exe',
            'ssh', 'scp', 'docker', 'curl'
        )
        foreach ($name in $blockedNames) {
            Set-Item -Path "Function:\${name}" -Value $blocked
        }
        $previousProviderKey = $env:RUNPOD_API_KEY
        $previousModelKey = $env:LLAMACPP_API_KEY
        try {
            $env:RUNPOD_API_KEY = $null
            $env:LLAMACPP_API_KEY = $null
            $first = ./scripts/runpod-provision.ps1 -OutputFormat Json | ConvertFrom-Json
            $second = ./scripts/runpod-provision.ps1 -OutputFormat Json | ConvertFrom-Json
        }
        finally {
            $env:RUNPOD_API_KEY = $previousProviderKey
            $env:LLAMACPP_API_KEY = $previousModelKey
            foreach ($name in $blockedNames) {
                Remove-Item -Path "Function:\${name}" -ErrorAction SilentlyContinue
            }
        }

        if ($first.mode -ne 'dry_run' -or $first.mutation_performed -ne $false -or
            $second.mode -ne 'dry_run' -or $second.mutation_performed -ne $false -or
            $first.plan_sha256 -ne $second.plan_sha256) {
            throw 'Fresh-clone provisioning plan is not stable and mutation-free.'
        }
        foreach ($forbiddenState in @(
            '.runpod/api-key',
            '.runpod/session.json',
            '.runpod/deployments/a100-pcie-80gb-q6-v1/state.json',
            '.runpod/deployments/a100-pcie-80gb-q6-v1/execute.lock'
        )) {
            if (Test-Path -LiteralPath $forbiddenState) {
                throw "Dry-run created forbidden state: ${forbiddenState}"
            }
        }

        $repositoryGate = @{
            SkipDryRun = $true
            SkipUnitTests = $SkipUnitTests
            UseHostTools = $UseHostTools
        }
        & ./scripts/test-repository.ps1 @repositoryGate
        if (@(& git status --porcelain --untracked-files=all).Count -ne 0) {
            throw 'Fresh-clone tests left tracked or unignored runtime state behind.'
        }
        Write-Host "Fresh-clone gate passed with plan SHA-256 $($first.plan_sha256)."
    }
    finally {
        Pop-Location
    }
}
finally {
    Pop-Location
    if (Test-Path -LiteralPath $cloneRoot) {
        $verifiedCloneRoot = [IO.Path]::GetFullPath($cloneRoot)
        if (-not $verifiedCloneRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([IO.Path]::GetFileName($verifiedCloneRoot)).StartsWith('qwen-eval-fresh-clone-', [StringComparison]::Ordinal)) {
            throw "Refusing to remove unsafe temporary path: ${verifiedCloneRoot}"
        }
        Remove-Item -LiteralPath $verifiedCloneRoot -Recurse -Force
    }
}

[CmdletBinding()]
param(
    [switch]$SkipUnitTests,
    [switch]$SkipDryRun,
    [switch]$UseHostTools
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

function Invoke-IsolatedRunPodDryRun {
    param([Parameter(Mandatory)][string]$SourceRoot)

    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $fixtureLeaf = 'qwen-eval-repository-dry-run-' + [guid]::NewGuid().ToString('N')
    $fixtureRoot = [IO.Path]::GetFullPath((Join-Path $temporaryBase $fixtureLeaf))
    if (
        -not $fixtureRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($fixtureRoot)).StartsWith(
            'qwen-eval-repository-dry-run-',
            [StringComparison]::Ordinal
        )
    ) {
        throw "Unsafe isolated repository DryRun path: ${fixtureRoot}"
    }

    $fixtureFiles = @(
        'config/models.json',
        'config/runpod-a100-pcie-deployment.json',
        'evals/cybench.py',
        'opencode.jsonc',
        'scripts/runpod-provision.ps1',
        'scripts/RunPod.Common.psm1',
        'scripts/ModelBackup.Common.psm1',
        'scripts/validate_runpod_deployment_manifest.py'
    )
    try {
        foreach ($relativePath in $fixtureFiles) {
            $sourcePath = Join-Path $SourceRoot $relativePath
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "Isolated repository DryRun source file is missing: ${relativePath}"
            }
            $fixturePath = Join-Path $fixtureRoot $relativePath
            [IO.Directory]::CreateDirectory((Split-Path -Parent $fixturePath)) | Out-Null
            Copy-Item -LiteralPath $sourcePath -Destination $fixturePath
        }

        $blocked = {
            throw "Cloud/external command was called during isolated repository DryRun: $($MyInvocation.MyCommand.Name)"
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
            $fixtureProvisioner = Join-Path $fixtureRoot 'scripts/runpod-provision.ps1'
            $result = & $fixtureProvisioner -OutputFormat Json | ConvertFrom-Json
        }
        finally {
            $env:RUNPOD_API_KEY = $previousProviderKey
            $env:LLAMACPP_API_KEY = $previousModelKey
            foreach ($name in $blockedNames) {
                Remove-Item -Path "Function:\${name}" -ErrorAction SilentlyContinue
            }
        }

        if ($result.mode -ne 'dry_run' -or $result.mutation_performed -ne $false) {
            throw 'Isolated provisioning dry-run reported a mutation.'
        }
        $expectedPlanPath = [IO.Path]::GetFullPath((Join-Path `
            $fixtureRoot `
            '.runpod/deployments/a100-pcie-80gb-q6-v1/plan.json'))
        $reportedPlanPath = [IO.Path]::GetFullPath([string]$result.plan_path)
        if (
            -not [string]::Equals($reportedPlanPath, $expectedPlanPath, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $expectedPlanPath -PathType Leaf)
        ) {
            throw 'Isolated provisioning dry-run did not bind its plan to the disposable fixture.'
        }
        foreach ($forbiddenFixtureState in @(
            '.runpod/api-key',
            '.runpod/session.json',
            '.runpod/deployments/a100-pcie-80gb-q6-v1/state.json',
            '.runpod/deployments/a100-pcie-80gb-q6-v1/execute.lock'
        )) {
            if (Test-Path -LiteralPath (Join-Path $fixtureRoot $forbiddenFixtureState)) {
                throw "Isolated provisioning dry-run created forbidden state: ${forbiddenFixtureState}"
            }
        }
        return $result
    }
    finally {
        if (Test-Path -LiteralPath $fixtureRoot) {
            $verifiedFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
            if (
                -not $verifiedFixtureRoot.StartsWith(
                    $temporaryBase,
                    [StringComparison]::OrdinalIgnoreCase
                ) -or
                -not ([IO.Path]::GetFileName($verifiedFixtureRoot)).StartsWith(
                    'qwen-eval-repository-dry-run-',
                    [StringComparison]::Ordinal
                )
            ) {
                throw "Refusing to remove unsafe isolated DryRun path: ${verifiedFixtureRoot}"
            }
            Remove-Item -LiteralPath $verifiedFixtureRoot -Recurse -Force
        }
    }
}

Push-Location $projectRoot
try {
    $trackedFiles = @(& git ls-files)
    if ($LASTEXITCODE -ne 0 -or $trackedFiles.Count -eq 0) {
        throw 'Repository gate requires a Git repository with tracked files.'
    }

    $powerShellFiles = @($trackedFiles | Where-Object { $_ -match '\.(ps1|psm1)$' })
    foreach ($path in $powerShellFiles) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $projectRoot $path),
            [ref]$tokens,
            [ref]$errors
        ) | Out-Null
        if ($errors.Count -ne 0) {
            throw "PowerShell parser rejected ${path}: $($errors[0].Message)"
        }
    }

    $shellFiles = @($trackedFiles | Where-Object { $_ -like '*.sh' })
    $hostBash = $null
    if ($UseHostTools) {
        $hostBashCandidates = @()
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
            if ($null -ne $gitCommand) {
                $gitRoot = Split-Path -Parent (Split-Path -Parent $gitCommand.Source)
                $hostBashCandidates += Join-Path $gitRoot 'bin\bash.exe'
            }
        }
        else {
            $hostBashCommand = Get-Command bash -ErrorAction SilentlyContinue
            if ($null -ne $hostBashCommand) {
                $hostBashCandidates += $hostBashCommand.Source
            }
        }
        $hostBash = @($hostBashCandidates | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        } | Select-Object -First 1)[0]
        if ([string]::IsNullOrWhiteSpace([string]$hostBash)) {
            throw 'Host-tool repository gate requires Git Bash on Windows or bash on PATH elsewhere.'
        }
    }
    foreach ($path in $shellFiles) {
        if ($UseHostTools) {
            & $hostBash -n -- $path
        }
        else {
            $wslPath = $path -replace '\\', '/'
            & wsl.exe -d Ubuntu-24.04 --cd $projectRoot -- /bin/bash -n -- $wslPath
        }
        if ($LASTEXITCODE -ne 0) {
            throw "bash -n rejected ${path}."
        }
    }

    $pythonFiles = @($trackedFiles | Where-Object { $_ -like '*.py' })
    $compileScript = @'
import ast
import pathlib
import sys

for filename in sys.argv[1:]:
    source = pathlib.Path(filename).read_text(encoding='utf-8')
    ast.parse(source, filename=filename)
    compile(source, filename, 'exec')
'@
    & python -c $compileScript @pythonFiles
    if ($LASTEXITCODE -ne 0) {
        throw 'Python AST/compile gate failed.'
    }

    foreach ($path in @($trackedFiles | Where-Object { $_ -like 'config/*.json' })) {
        Get-Content -Raw -LiteralPath $path | ConvertFrom-Json | Out-Null
    }

    & python scripts/validate_model_manifest.py
    if ($LASTEXITCODE -ne 0) {
        throw 'Model manifest validation failed.'
    }
    & python scripts/validate_runpod_deployment_manifest.py `
        --manifest config/runpod-a100-pcie-deployment.json `
        --quiet
    if ($LASTEXITCODE -ne 0) {
        throw 'A100 deployment manifest validation failed.'
    }

    if (-not $SkipDryRun) {
        $dryRun = Invoke-IsolatedRunPodDryRun -SourceRoot $projectRoot
    }

    if (-not $SkipUnitTests) {
        if ($UseHostTools) {
            & python -B -m unittest discover -s tests
        }
        else {
            & wsl.exe -d Ubuntu-24.04 --cd $projectRoot -- `
                /home/qwen-eval/.local/share/qwen-eval/.venv/bin/python `
                -m unittest discover -s tests
        }
        if ($LASTEXITCODE -ne 0) {
            throw 'Unit-test gate failed.'
        }
    }

    & git diff --check
    if ($LASTEXITCODE -ne 0) {
        throw 'git diff --check failed.'
    }

    Write-Host "Repository gate passed: $($trackedFiles.Count) tracked files."
}
finally {
    Pop-Location
}

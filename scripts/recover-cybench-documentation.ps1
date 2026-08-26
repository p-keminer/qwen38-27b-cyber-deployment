param(
    [Parameter(Mandatory = $true)][string]$EvalPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [string]$SampleId,
    [string]$SampleUuid,
    [ValidatePattern('^[A-Za-z0-9._-]+$')][string]$ModelAlias,
    [switch]$DryRun,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([bool]$DryRun -eq [bool]$Execute) {
    throw 'Specify exactly one of -DryRun or -Execute.'
}
if ($DryRun -and $ModelAlias) {
    throw 'Do not provide -ModelAlias with -DryRun.'
}

$projectWindows = Split-Path -Parent $PSScriptRoot
$projectPrefix = $projectWindows.TrimEnd('\') + '\'

function Get-ProjectRelativeExistingFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "File does not exist: $resolved"
    }
    if (-not $resolved.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path must be inside the project: $resolved"
    }
    return $resolved.Substring($projectPrefix.Length).Replace('\', '/')
}

function Get-ProjectRelativeOutputFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
    }
    $parent = Split-Path -Parent $candidate
    $leaf = Split-Path -Leaf $candidate
    $resolvedParent = (Resolve-Path -LiteralPath $parent).Path
    $resolved = Join-Path $resolvedParent $leaf
    if (-not $resolved.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Output path must be inside the project: $resolved"
    }
    if ([System.IO.Path]::GetExtension($resolved) -ne '.json') {
        throw 'The recovery sidecar must use a .json extension.'
    }
    return $resolved.Substring($projectPrefix.Length).Replace('\', '/')
}

$sourceRelative = Get-ProjectRelativeExistingFile -Path $EvalPath
if ([System.IO.Path]::GetExtension($sourceRelative) -ne '.eval') {
    throw 'EvalPath must identify one .eval file.'
}
$outputRelative = Get-ProjectRelativeOutputFile -Path $OutputPath
if ($Execute -and (Test-Path -LiteralPath $OutputPath)) {
    throw "Refusing to overwrite an existing sidecar: $OutputPath"
}

$arguments = @(
    'scripts/recover-cybench-documentation.sh',
    '--source',
    $sourceRelative,
    '--output',
    $outputRelative
)
if ($SampleId) {
    $arguments += @('--sample-id', $SampleId)
}
if ($SampleUuid) {
    $arguments += @('--sample-uuid', $SampleUuid)
}

$previousWslEnv = $env:WSLENV
$previousApiKey = $env:LLAMACPP_API_KEY
$previousBaseUrl = $env:LLAMACPP_BASE_URL
try {
    if ($DryRun) {
        $arguments += '--dry-run'
    }
    else {
        Import-Module (Join-Path $PSScriptRoot 'RunPod.Common.psm1') -Force
        $session = Get-RunPodSession
        $session = Start-RunPodTunnel -Session $session
        Start-RunPodWslTunnel -Session $session
        if (-not $ModelAlias) {
            $ModelAlias = [string]$session.ActiveAlias
        }
        if ($ModelAlias -notmatch '^[A-Za-z0-9._-]+$') {
            throw "Invalid model alias in the current RunPod session: $ModelAlias"
        }
        $env:LLAMACPP_API_KEY = Get-RunPodApiKey
        $env:LLAMACPP_BASE_URL = "http://127.0.0.1:$($session.LocalPort)/v1"
        $passThrough = 'LLAMACPP_API_KEY/u:LLAMACPP_BASE_URL/u'
        $env:WSLENV = if ([string]::IsNullOrWhiteSpace($previousWslEnv)) {
            $passThrough
        }
        else {
            "$previousWslEnv`:$passThrough"
        }
        $arguments += @(
            '--execute',
            '--model',
            "openai-api/llamacpp/$ModelAlias"
        )
    }

    wsl.exe -d Ubuntu-24.04 --cd $projectWindows -- bash @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Cybench documentation recovery failed with exit code $LASTEXITCODE."
    }
}
finally {
    $env:WSLENV = $previousWslEnv
    if ($null -eq $previousApiKey) {
        Remove-Item Env:LLAMACPP_API_KEY -ErrorAction SilentlyContinue
    }
    else {
        $env:LLAMACPP_API_KEY = $previousApiKey
    }
    if ($null -eq $previousBaseUrl) {
        Remove-Item Env:LLAMACPP_BASE_URL -ErrorAction SilentlyContinue
    }
    else {
        $env:LLAMACPP_BASE_URL = $previousBaseUrl
    }
}

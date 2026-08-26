param(
    [string]$LogPath,
    [string]$ReviewPacket,
    [string]$ReviewAssessments,
    [switch]$Finalize
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectWindows = Split-Path -Parent $PSScriptRoot

function Get-ProjectRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $prefix = $projectWindows.TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path must be inside the project: $resolved"
    }
    return $resolved.Substring($prefix.Length).Replace('\', '/')
}

if ($Finalize) {
    if ($LogPath) {
        throw 'Do not combine -Finalize with -LogPath.'
    }
    if (-not $ReviewPacket) {
        $ReviewPacket = Get-ChildItem `
            -LiteralPath (Join-Path $projectWindows 'artifacts\reviews') `
            -Filter 'review-packet.json' `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $ReviewPacket) {
        throw 'No review-packet.json found. Build a review packet first.'
    }
    $arguments = @(
        'scripts/review-cybench.sh',
        'finalize',
        (Get-ProjectRelativePath -Path $ReviewPacket)
    )
    if ($ReviewAssessments) {
        $arguments += @(
            '--assessments',
            (Get-ProjectRelativePath -Path $ReviewAssessments)
        )
    }
}
else {
    if ($ReviewPacket -or $ReviewAssessments) {
        throw 'Use -ReviewPacket/-ReviewAssessments only with -Finalize.'
    }
    if (-not $LogPath) {
        $LogPath = Get-ChildItem `
            -LiteralPath (Join-Path $projectWindows 'artifacts\logs') `
            -Directory `
            -ErrorAction SilentlyContinue |
            Where-Object {
                Get-ChildItem -LiteralPath $_.FullName -Filter '*.eval' -File -Recurse |
                    Select-Object -First 1
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $LogPath) {
        throw 'No Cybench .eval log found. Supply -LogPath after a run completes.'
    }
    $arguments = @(
        'scripts/review-cybench.sh',
        'build',
        (Get-ProjectRelativePath -Path $LogPath)
    )
}

wsl.exe -d Ubuntu-24.04 --cd $projectWindows -- bash @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Cybench review command failed with exit code $LASTEXITCODE."
}

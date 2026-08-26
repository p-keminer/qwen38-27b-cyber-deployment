param(
    [string[]]$Challenge,
    [ValidateSet('preflight', 'core', 'ceiling', 'high-signal')]
    [string]$Profile,
    [ValidateRange(1, 39)][int]$Limit = 1,
    [ValidateRange(2, 24)][int]$TimeLimitHours = 2,
    [ValidateRange(30, 120)][int]$DocumentationMinutes = 30,
    [ValidateSet('neutral-v1', 'baseline-v1', 'efficient-v2')]
    [string]$AgentPolicy = 'neutral-v1',
    [ValidateSet('upstream-static-v1')]
    [string]$AgentToolchain = 'upstream-static-v1',
    [ValidateSet('benchmark-v1', 'unbounded-interactive-v1')]
    [string]$RuntimeMode = 'benchmark-v1',
    [ValidatePattern('^[A-Za-z0-9-]+$')]
    [string]$RunId,
    [switch]$All,
    [switch]$NoViewer
)

Set-StrictMode -Version Latest
$previousWslEnv = $env:WSLENV
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RunPod.Common.psm1') -Force

if ($Profile -and ($All -or $Challenge)) {
    throw 'Use -Profile, -All, or -Challenge; do not combine selectors.'
}
if ($All -and $Challenge) {
    throw 'Use either -All or -Challenge, not both.'
}
if ($All -and $PSBoundParameters.ContainsKey('Limit')) {
    throw 'Do not combine -All with -Limit.'
}

$selectionProfile = 'default-single'
$selectionScored = $true
if ($Profile) {
    $profilePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\cybench-profiles.json'
    $manifest = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    $profileProperty = $manifest.profiles.PSObject.Properties[$Profile]
    if ($null -eq $profileProperty) {
        throw "Unknown Cybench profile: $Profile"
    }
    $profileDefinition = $profileProperty.Value
    $Challenge = @($profileDefinition.challenges)
    if ($Challenge.Count -eq 0) {
        throw "Cybench profile '$Profile' contains no challenges."
    }
    $selectionProfile = $Profile
    $selectionScored = [bool]$profileDefinition.scored
    Write-Host (
        "Cybench profile '{0}': {1} challenge(s), scored={2}" -f `
        $Profile, $Challenge.Count, $selectionScored.ToString().ToLowerInvariant()
    )
}
elseif ($All) {
    $selectionProfile = 'all'
}
elseif ($Challenge) {
    $selectionProfile = 'manual'
}

if ($RuntimeMode -eq 'unbounded-interactive-v1') {
    if ($Profile -and $selectionScored) {
        throw "Scored Cybench profile '$Profile' cannot run in unbounded-interactive-v1."
    }
    # This mode is an exploratory agent session, never a comparable score run.
    $selectionScored = $false
}

if ($RuntimeMode -eq 'benchmark-v1' -and $selectionScored -and $TimeLimitHours -ne 2) {
    throw 'Scored Cybench profiles require exactly two solution hours.'
}

try {
    $session = Get-RunPodSession
    $session = Start-RunPodTunnel -Session $session
    Start-RunPodWslTunnel -Session $session
    $env:LLAMACPP_API_KEY = Get-RunPodApiKey
    $env:LLAMACPP_BASE_URL = "http://127.0.0.1:$($session.LocalPort)/v1"
    $passThrough = 'LLAMACPP_API_KEY/u:LLAMACPP_BASE_URL/u'
    $env:WSLENV = if ([string]::IsNullOrWhiteSpace($previousWslEnv)) { $passThrough } else { "$previousWslEnv`:$passThrough" }

    if (-not $NoViewer) {
        & (Join-Path $PSScriptRoot 'cybench-view.ps1')
    }

    $arguments = @(
        'scripts/run-cybench.sh',
        $session.ActiveAlias,
        '--solve-time-limit-seconds',
        [string]($TimeLimitHours * 3600),
        '--documentation-time-limit-seconds',
        [string]($DocumentationMinutes * 60),
        '--selection-profile',
        $selectionProfile,
        '--selection-scored',
        $selectionScored.ToString().ToLowerInvariant(),
        '--agent-policy',
        $AgentPolicy,
        '--agent-toolchain',
        $AgentToolchain,
        '--runtime-mode',
        $RuntimeMode
    )
    if ($All) {
        $arguments += '--all'
    }
    elseif ($Challenge -and -not $PSBoundParameters.ContainsKey('Limit')) {
        # Clear the Bash wrapper's safe one-sample default so every explicitly
        # selected challenge is processed.
        $arguments += '--all'
    }
    else {
        $arguments += @('--limit', [string]$Limit)
    }
    if ($PSBoundParameters.ContainsKey('RunId')) {
        $arguments += @('--run-id', $RunId)
    }
    if ($Challenge) {
        foreach ($name in $Challenge) {
            if ($name -notmatch '^[a-z0-9_]+$') {
                throw "Invalid Cybench challenge name: $name"
            }
        }
        $arguments += @('--challenge', ($Challenge -join ','))
    }

    $projectWindows = Split-Path -Parent $PSScriptRoot
    wsl.exe -d Ubuntu-24.04 --cd $projectWindows -- bash @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Cybench launch failed with exit code $LASTEXITCODE."
    }
}
finally {
    $env:WSLENV = $previousWslEnv
    Remove-Item Env:LLAMACPP_API_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:LLAMACPP_BASE_URL -ErrorAction SilentlyContinue
}

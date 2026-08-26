param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) {
    throw 'Docker Desktop is required.'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$image = 'qwen-eval/opencode:0.0.0-beta-17898'
$containerNames = @(
    'qwen-eval-ui-proxy',
    'qwen-eval-opencode',
    'qwen-eval-model-gateway',
    'qwen-eval-controlled-web'
)
$networkNames = @(
    'qwen-eval-agent_agent-internal',
    'qwen-eval-agent_gateway-egress',
    'qwen-eval-agent_ui-ingress',
    'qwen-eval-agent_controlled-web-egress'
)

function Get-DockerNames {
    param([Parameter(Mandatory)][ValidateSet('container', 'network')][string]$Kind)

    $arguments = if ($Kind -eq 'container') {
        @('container', 'ls', '--all', '--format', '{{.Names}}')
    }
    else {
        @('network', 'ls', '--format', '{{.Name}}')
    }
    $names = @(& docker.exe @arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "Docker failed to list $Kind resources."
    }
    return @($names | ForEach-Object { ([string]$_).Trim() })
}

function Assert-TargetsAbsent {
    $containers = @(Get-DockerNames -Kind container)
    $networks = @(Get-DockerNames -Kind network)
    foreach ($name in $containerNames) {
        if ($containers -ccontains $name) {
            throw "Cleanup fixture target already exists or survived: $name"
        }
    }
    foreach ($name in $networkNames) {
        if ($networks -ccontains $name) {
            throw "Cleanup fixture target already exists or survived: $name"
        }
    }
}

Assert-TargetsAbsent
& docker.exe image inspect $image 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    & docker.exe build `
        --file (Join-Path $projectRoot 'agent\Dockerfile.opencode') `
        --tag $image `
        (Join-Path $projectRoot 'agent') | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to build the cleanup-fixture image.'
    }
}

$suffix = [Guid]::NewGuid().ToString('N')
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempRoot = [IO.Path]::GetFullPath((Join-Path $tempBase "qwen-eval-cleanup-$suffix"))
if (-not $tempRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe cleanup-fixture temp path: $tempRoot"
}
$tempScripts = Join-Path $tempRoot 'scripts'
$createdContainerIds = @()
$createdNetworkIds = @()

try {
    New-Item -ItemType Directory -Path $tempScripts | Out-Null
    Copy-Item `
        -LiteralPath (Join-Path $PSScriptRoot 'RunPod.Common.psm1') `
        -Destination (Join-Path $tempScripts 'RunPod.Common.psm1')
    Copy-Item `
        -LiteralPath (Join-Path $PSScriptRoot 'runpod-stop.ps1') `
        -Destination (Join-Path $tempScripts 'runpod-stop.ps1')
    Import-Module (Join-Path $tempScripts 'RunPod.Common.psm1') -Force

    $session = [pscustomobject]@{
        Sentinel = 'cleanup-fixture'
        OpenCodePort = 4096
        OpenCodeRuntime = 'isolated-docker'
        OpenCodeNetworkMode = 'controlled-web-v1'
    }
    Save-RunPodSession -Session $session
    $sessionPath = Join-Path $tempRoot '.runpod\session.json'
    $sessionBeforeForeignCheck = [IO.File]::ReadAllText($sessionPath)

    $previousPath = $env:PATH
    $dockerMissingRejected = $false
    try {
        $env:PATH = ''
        try {
            Stop-OpenCodeWeb -Session $session
        }
        catch {
            if ($_.Exception.Message -like 'Docker is required to ownership-check*') {
                $dockerMissingRejected = $true
            }
            else {
                throw
            }
        }
    }
    finally {
        $env:PATH = $previousPath
    }
    if (-not $dockerMissingRejected) {
        throw 'Stop-OpenCodeWeb did not fail closed when docker.exe was unavailable.'
    }
    if (
        [IO.File]::ReadAllText($sessionPath) -cne $sessionBeforeForeignCheck -or
        $session.OpenCodeNetworkMode -ne 'controlled-web-v1'
    ) {
        throw 'Session state changed while Docker ownership could not be checked.'
    }

    foreach ($networkName in $networkNames) {
        $networkId = (& docker.exe network create `
            --label com.docker.compose.project=qwen-eval-agent `
            $networkName).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($networkId)) {
            throw "Failed to create cleanup-fixture network '$networkName'."
        }
        $createdNetworkIds += $networkId
    }

    foreach ($containerName in $containerNames) {
        $projectLabel = if ($containerName -eq 'qwen-eval-controlled-web') {
            'foreign-project'
        }
        else {
            'qwen-eval-agent'
        }
        $containerId = (& docker.exe run --detach `
            --name $containerName `
            --label "com.docker.compose.project=$projectLabel" `
            --network qwen-eval-agent_agent-internal `
            --entrypoint sh `
            $image `
            -c 'while :; do sleep 3600; done').Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($containerId)) {
            throw "Failed to create cleanup-fixture container '$containerName'."
        }
        $createdContainerIds += $containerId
    }

    $foreignRejected = $false
    try {
        Stop-OpenCodeWeb -Session $session
    }
    catch {
        if ($_.Exception.Message -like "Refusing to remove unexpected container 'qwen-eval-controlled-web'.*") {
            $foreignRejected = $true
        }
        else {
            throw
        }
    }
    if (-not $foreignRejected) {
        throw 'Stop-OpenCodeWeb did not reject the foreign exact-name container.'
    }
    $containersAfterRejection = @(Get-DockerNames -Kind container)
    $networksAfterRejection = @(Get-DockerNames -Kind network)
    foreach ($name in $containerNames) {
        if ($containersAfterRejection -cnotcontains $name) {
            throw "Foreign-resource preflight caused partial container cleanup: $name"
        }
    }
    foreach ($name in $networkNames) {
        if ($networksAfterRejection -cnotcontains $name) {
            throw "Foreign-resource preflight caused partial network cleanup: $name"
        }
    }
    if (
        [IO.File]::ReadAllText($sessionPath) -cne $sessionBeforeForeignCheck -or
        $session.OpenCodeNetworkMode -ne 'controlled-web-v1'
    ) {
        throw 'Session state changed despite rejected cleanup.'
    }

    $foreignId = $createdContainerIds[-1]
    & docker.exe container rm --force $foreignId | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to replace the foreign cleanup-fixture container.'
    }
    $ownedProxyId = (& docker.exe run --detach `
        --name qwen-eval-controlled-web `
        --label com.docker.compose.project=qwen-eval-agent `
        --network qwen-eval-agent_agent-internal `
        --entrypoint sh `
        $image `
        -c 'while :; do sleep 3600; done').Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ownedProxyId)) {
        throw 'Failed to create the owned controlled-web cleanup fixture.'
    }
    $createdContainerIds += $ownedProxyId

    $foreignNetworkId = $createdNetworkIds[-1]
    & docker.exe network rm $foreignNetworkId | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to replace the foreign cleanup-fixture network.'
    }
    $replacementForeignNetworkId = (& docker.exe network create `
        --label com.docker.compose.project=foreign-project `
        qwen-eval-agent_controlled-web-egress).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($replacementForeignNetworkId)) {
        throw 'Failed to create the foreign exact-name network fixture.'
    }
    $createdNetworkIds += $replacementForeignNetworkId
    $foreignNetworkRejected = $false
    try {
        Stop-OpenCodeWeb -Session $session
    }
    catch {
        if ($_.Exception.Message -like "Refusing to remove unexpected network 'qwen-eval-agent_controlled-web-egress'.*") {
            $foreignNetworkRejected = $true
        }
        else {
            throw
        }
    }
    if (-not $foreignNetworkRejected) {
        throw 'Stop-OpenCodeWeb did not reject the foreign exact-name network.'
    }
    $containersAfterNetworkRejection = @(Get-DockerNames -Kind container)
    $networksAfterNetworkRejection = @(Get-DockerNames -Kind network)
    foreach ($name in $containerNames) {
        if ($containersAfterNetworkRejection -cnotcontains $name) {
            throw "Foreign-network preflight caused partial container cleanup: $name"
        }
    }
    foreach ($name in $networkNames) {
        if ($networksAfterNetworkRejection -cnotcontains $name) {
            throw "Foreign-network preflight caused partial network cleanup: $name"
        }
    }
    if ([IO.File]::ReadAllText($sessionPath) -cne $sessionBeforeForeignCheck) {
        throw 'Session state changed despite rejected foreign-network cleanup.'
    }
    & docker.exe network rm $replacementForeignNetworkId | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to replace the foreign exact-name network fixture.'
    }
    $replacementOwnedNetworkId = (& docker.exe network create `
        --label com.docker.compose.project=qwen-eval-agent `
        qwen-eval-agent_controlled-web-egress).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($replacementOwnedNetworkId)) {
        throw 'Failed to recreate the owned controlled-web egress network fixture.'
    }
    $createdNetworkIds += $replacementOwnedNetworkId

    Stop-OpenCodeWeb -Session $session
    Assert-TargetsAbsent
    $savedSession = Get-Content -LiteralPath $sessionPath -Raw -Encoding utf8 | ConvertFrom-Json
    if (
        [string]$savedSession.Sentinel -ne 'cleanup-fixture' -or
        $null -ne $savedSession.OpenCodePort -or
        $null -ne $savedSession.OpenCodeRuntime -or
        $null -ne $savedSession.OpenCodeNetworkMode
    ) {
        throw 'Session was not reset only after confirmed owned-resource cleanup.'
    }

    $stoppedSession = [pscustomobject]@{
        Sentinel = 'stopped-session-fixture'
        LifecycleStatus = 'stopped_after_failure'
        OpenCodePort = 4096
        OpenCodeRuntime = 'isolated-docker'
        OpenCodeNetworkMode = 'controlled-web-v1'
    }
    Save-RunPodSession -Session $stoppedSession
    foreach ($networkName in $networkNames) {
        $networkId = (& docker.exe network create `
            --label com.docker.compose.project=qwen-eval-agent `
            $networkName).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($networkId)) {
            throw "Failed to create stopped-session fixture network '$networkName'."
        }
        $createdNetworkIds += $networkId
    }
    foreach ($containerName in $containerNames) {
        $containerId = (& docker.exe run --detach `
            --name $containerName `
            --label com.docker.compose.project=qwen-eval-agent `
            --network qwen-eval-agent_agent-internal `
            --entrypoint sh `
            $image `
            -c 'while :; do sleep 3600; done').Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($containerId)) {
            throw "Failed to create stopped-session fixture container '$containerName'."
        }
        $createdContainerIds += $containerId
    }
    & (Join-Path $tempScripts 'runpod-stop.ps1')
    Assert-TargetsAbsent
    $savedStoppedSession = Get-Content -LiteralPath $sessionPath -Raw -Encoding utf8 | ConvertFrom-Json
    if (
        [string]$savedStoppedSession.Sentinel -ne 'stopped-session-fixture' -or
        [string]$savedStoppedSession.LifecycleStatus -ne 'stopped_after_failure' -or
        $null -ne $savedStoppedSession.OpenCodePort -or
        $null -ne $savedStoppedSession.OpenCodeRuntime -or
        $null -ne $savedStoppedSession.OpenCodeNetworkMode
    ) {
        throw 'Stopped-session local cleanup did not preserve remote state while resetting GUI state.'
    }

    Write-Host 'OpenCode cleanup lifecycle: foreign rejected without partial deletion; owned resources removed; session reset after verification.'
    Write-Host 'OpenCode cleanup lifecycle: stopped/unqualified session still permits local cleanup while tunnel actions remain skipped.'
    Write-Host 'OpenCode cleanup lifecycle: OK'
}
finally {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        foreach ($containerId in $createdContainerIds) {
            if ([string]$containerId -match '^[0-9a-f]{12,64}$') {
                & docker.exe container rm --force $containerId 2>$null | Out-Null
            }
        }
        foreach ($networkId in $createdNetworkIds) {
            if ([string]$networkId -match '^[0-9a-f]{12,64}$') {
                & docker.exe network rm $networkId 2>$null | Out-Null
            }
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if (Test-Path -LiteralPath $tempRoot -PathType Container) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

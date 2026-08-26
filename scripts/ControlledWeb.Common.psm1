Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DockerInspectionRecord {
    param(
        [Parameter(Mandatory)][ValidateSet('container', 'network')][string]$Kind,
        [Parameter(Mandatory)][string]$Name
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        if ($Kind -eq 'container') {
            $inspectionOutput = @(& docker.exe container inspect $Name 2>$null)
        }
        else {
            $inspectionOutput = @(& docker.exe network inspect $Name 2>$null)
        }
        $inspectionExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($inspectionExitCode -ne 0) {
        return $null
    }
    try {
        $parsedInspection = ($inspectionOutput -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch {
        throw "Docker returned invalid JSON while inspecting $Kind '$Name'."
    }
    if ($parsedInspection -is [Array]) {
        if ($parsedInspection.Count -ne 1) {
            throw "Docker returned an ambiguous inspection for $Kind '$Name'."
        }
        return $parsedInspection[0]
    }
    return $parsedInspection
}

function Get-ComposeProjectLabel {
    param(
        [Parameter(Mandatory)]$Inspection,
        [Parameter(Mandatory)][ValidateSet('container', 'network')][string]$Kind
    )

    $labels = if ($Kind -eq 'container') {
        $Inspection.Config.Labels
    }
    else {
        $Inspection.Labels
    }
    if ($null -eq $labels) {
        return ''
    }
    $property = $labels.PSObject.Properties['com.docker.compose.project']
    if ($null -eq $property) {
        return ''
    }
    return ([string]$property.Value).Trim()
}

function Get-ControlledWebRuntimeMode {
    param([string]$ExpectedDenyHost = '')

    if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) {
        throw 'Docker is required to attest the OpenCode network mode.'
    }
    $agentInspection = Get-DockerInspectionRecord -Kind container -Name 'qwen-eval-opencode'
    $proxyInspection = Get-DockerInspectionRecord -Kind container -Name 'qwen-eval-controlled-web'
    if ($null -eq $agentInspection) {
        if ($null -ne $proxyInspection) {
            throw 'The controlled-web proxy exists without its OpenCode agent container.'
        }
        return 'offline-v1'
    }
    if ((Get-ComposeProjectLabel -Inspection $agentInspection -Kind container) -ne 'qwen-eval-agent') {
        throw "The OpenCode container does not belong to Compose project 'qwen-eval-agent'."
    }
    if ($agentInspection.State.Running -ne $true) {
        throw 'The OpenCode container exists but is not running.'
    }
    $modeProperty = $agentInspection.Config.Labels.PSObject.Properties['qwen-eval.network-mode']
    if (
        $null -eq $modeProperty -or
        [string]$modeProperty.Value -notin @('offline-v1', 'controlled-web-v1')
    ) {
        throw 'The OpenCode container has no valid network-mode attestation label.'
    }
    $mode = [string]$modeProperty.Value
    $agentNetworks = @($agentInspection.NetworkSettings.Networks.PSObject.Properties.Name)
    if (
        $agentNetworks.Count -ne 1 -or
        [string]$agentNetworks[0] -ne 'qwen-eval-agent_agent-internal'
    ) {
        throw "The OpenCode container has unexpected networks: $($agentNetworks -join ', ')."
    }
    $agentEnvironment = @($agentInspection.Config.Env | ForEach-Object { [string]$_ })
    $egressEnvironment = @(
        $agentEnvironment |
            Where-Object {
                $_ -cmatch '^(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy|ALL_PROXY|all_proxy|NODE_USE_ENV_PROXY)='
            }
    )
    if ($mode -eq 'offline-v1') {
        if ($null -ne $proxyInspection) {
            throw 'The offline OpenCode container has an unexpected controlled-web proxy.'
        }
        if ($egressEnvironment.Count -ne 0) {
            throw 'The offline OpenCode container unexpectedly contains proxy environment variables.'
        }
        return $mode
    }

    $expectedAgentEnvironment = @(
        'HTTP_PROXY=http://controlled-web-proxy:3128',
        'HTTPS_PROXY=http://controlled-web-proxy:3128',
        'http_proxy=http://controlled-web-proxy:3128',
        'https_proxy=http://controlled-web-proxy:3128',
        'NODE_USE_ENV_PROXY=1'
    ) | Sort-Object
    $actualAgentEnvironment = @($egressEnvironment | Sort-Object)
    if (
        $actualAgentEnvironment.Count -ne $expectedAgentEnvironment.Count -or
        (Compare-Object -CaseSensitive -ReferenceObject $expectedAgentEnvironment -DifferenceObject $actualAgentEnvironment)
    ) {
        throw 'The controlled-web OpenCode container has unexpected proxy environment variables.'
    }
    if ($null -eq $proxyInspection) {
        throw 'The controlled-web OpenCode container has no proxy container.'
    }
    $inspection = $proxyInspection
    if ((Get-ComposeProjectLabel -Inspection $inspection -Kind container) -ne 'qwen-eval-agent') {
        throw "The controlled-web container does not belong to Compose project 'qwen-eval-agent'."
    }
    $proxyModeProperty = $inspection.Config.Labels.PSObject.Properties['qwen-eval.network-mode']
    if ($null -eq $proxyModeProperty -or [string]$proxyModeProperty.Value -ne 'controlled-web-v1') {
        throw 'The controlled-web container has no valid network-mode attestation label.'
    }
    if ($inspection.State.Running -ne $true) {
        throw 'The controlled-web container exists but is not running.'
    }
    $actualNetworks = @($inspection.NetworkSettings.Networks.PSObject.Properties.Name | Sort-Object)
    $expectedNetworks = @(
        'qwen-eval-agent_agent-internal',
        'qwen-eval-agent_controlled-web-egress'
    ) | Sort-Object
    if (
        $actualNetworks.Count -ne $expectedNetworks.Count -or
        (Compare-Object -ReferenceObject $expectedNetworks -DifferenceObject $actualNetworks)
    ) {
        throw "The controlled-web container has unexpected networks: $($actualNetworks -join ', ')."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedDenyHost)) {
        $denyEntries = @(
            $inspection.Config.Env |
                Where-Object { [string]$_ -like 'CONTROLLED_WEB_DENY_HOSTS=*' }
        )
        $expectedEntry = "CONTROLLED_WEB_DENY_HOSTS=$ExpectedDenyHost"
        if ($denyEntries.Count -ne 1 -or [string]$denyEntries[0] -cne $expectedEntry) {
            throw 'The controlled-web container is not bound to the current RunPod SSH host denylist.'
        }
    }
    return $mode
}

function Remove-ControlledWebResources {
    if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) {
        return
    }

    foreach ($resource in @(
        [pscustomobject]@{ Kind = 'container'; Name = 'qwen-eval-controlled-web' },
        [pscustomobject]@{ Kind = 'network'; Name = 'qwen-eval-agent_controlled-web-egress' }
    )) {
        $inspection = Get-DockerInspectionRecord -Kind $resource.Kind -Name $resource.Name
        if ($null -eq $inspection) {
            continue
        }
        if ((Get-ComposeProjectLabel -Inspection $inspection -Kind $resource.Kind) -ne 'qwen-eval-agent') {
            throw "Refusing to remove unexpected $($resource.Kind) '$($resource.Name)'."
        }
        if ($resource.Kind -eq 'container') {
            & docker.exe container rm --force $resource.Name | Out-Null
        }
        else {
            & docker.exe network rm $resource.Name | Out-Null
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to remove controlled-web $($resource.Kind) '$($resource.Name)'."
        }
    }
}

Export-ModuleMember -Function @(
    'Get-ControlledWebRuntimeMode',
    'Remove-ControlledWebResources'
)

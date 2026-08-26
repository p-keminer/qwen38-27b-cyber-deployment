param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) {
    throw 'Docker Desktop is required.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$suffix = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$internalNetwork = "qwen-controlled-internal-smoke-$suffix"
$egressNetwork = "qwen-controlled-egress-smoke-$suffix"
$proxyContainer = "qwen-controlled-proxy-smoke-$suffix"
$agentContainer = "qwen-controlled-agent-smoke-$suffix"
$modelContainer = "qwen-controlled-model-smoke-$suffix"
$publicTargetContainer = "qwen-controlled-public-smoke-$suffix"
$createdContainers = @(
    $proxyContainer,
    $agentContainer,
    $modelContainer,
    $publicTargetContainer
)
$createdNetworks = @($internalNetwork, $egressNetwork)

function Get-ProxyStatus {
    param(
        [Parameter(Mandatory)][string]$Url,
        [switch]$Insecure
    )

    $arguments = @(
        'exec', $agentContainer,
        'curl', '--silent', '--show-error',
        '--connect-timeout', '3', '--max-time', '10',
        '--proxy', 'http://controlled-web-proxy:3128',
        '--noproxy', 'qwen-proxy-bypass-disabled.invalid',
        '--output', '/dev/null', '--write-out', '%{http_code}:%{http_connect}'
    )
    if ($Insecure) {
        $arguments += '--insecure'
    }
    $arguments += $Url
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $rawStatus = (& docker.exe @arguments 2>$null).Trim()
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0 -and [string]::IsNullOrWhiteSpace($rawStatus)) {
        throw "Proxy request failed without an HTTP status: $Url"
    }
    $statusParts = @($rawStatus -split ':')
    if ($statusParts.Count -ne 2) {
        throw "Proxy request returned an invalid status tuple '$rawStatus': $Url"
    }
    if ($statusParts[0] -ne '000') {
        return $statusParts[0]
    }
    return $statusParts[1]
}

try {
    & docker.exe build `
        --file (Join-Path $projectRoot 'agent\Dockerfile.controlled-web') `
        --tag qwen-eval/controlled-web:1 `
        (Join-Path $projectRoot 'agent') | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to build the controlled-web proxy image.'
    }

    & docker.exe network create `
        --internal `
        --subnet 172.30.242.0/24 `
        $internalNetwork | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create the controlled internal smoke network.' }
    & docker.exe network create `
        --subnet 93.184.216.0/24 `
        $egressNetwork | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create the controlled egress smoke network.' }

    $targetCommand = @'
set -eu
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj /CN=93.184.216.35 \
  -keyout /tmp/key.pem -out /tmp/cert.pem >/dev/null 2>&1
openssl s_server -quiet -accept 443 -cert /tmp/cert.pem -key /tmp/key.pem -www &
exec python3 -m http.server 80 --bind 0.0.0.0
'@
    & docker.exe run --detach `
        --name $publicTargetContainer `
        --network $egressNetwork `
        --ip 93.184.216.35 `
        --user 0:0 `
        --entrypoint sh `
        qwen-eval/opencode:0.0.0-beta-17898 `
        -c $targetCommand | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to start the isolated public-looking test target.' }

    & docker.exe run --detach `
        --name $modelContainer `
        --read-only `
        --network $internalNetwork `
        --network-alias model-gateway `
        --ip 172.30.242.2 `
        --cap-drop ALL `
        --security-opt no-new-privileges:true `
        --entrypoint node `
        qwen-eval/opencode:0.0.0-beta-17898 `
        -e "require('node:http').createServer((q,s)=>s.end('model-alias-ok')).listen(18081,'0.0.0.0')" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to start the internal model-alias service.' }

    & docker.exe create `
        --name $proxyContainer `
        --read-only `
        --network $internalNetwork `
        --network-alias controlled-web-proxy `
        --ip 172.30.242.3 `
        --label qwen-eval.network-mode=controlled-web-v1 `
        --env CONTROLLED_WEB_DENY_HOSTS=93.184.216.34 `
        --cap-drop ALL `
        --security-opt no-new-privileges:true `
        --pids-limit 64 `
        --memory 128m `
        --cpus 0.25 `
        --tmpfs /tmp:rw,nosuid,nodev,noexec,size=8m,mode=1777 `
        qwen-eval/controlled-web:1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create the controlled-web proxy smoke container.' }
    & docker.exe network connect $egressNetwork $proxyContainer
    if ($LASTEXITCODE -ne 0) { throw 'Failed to attach proxy-only egress.' }
    & docker.exe start $proxyContainer | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to start the controlled-web proxy.' }

    & docker.exe run --detach `
        --name $agentContainer `
        --read-only `
        --user 10001:10001 `
        --network $internalNetwork `
        --dns 127.0.0.1 `
        --add-host model-gateway:172.30.242.2 `
        --add-host controlled-web-proxy:172.30.242.3 `
        --cap-drop ALL `
        --security-opt no-new-privileges:true `
        --workdir /workspace/agent-workspace `
        --mount "type=bind,source=$projectRoot,target=/workspace" `
        --env HTTP_PROXY=http://controlled-web-proxy:3128 `
        --env HTTPS_PROXY=http://controlled-web-proxy:3128 `
        --env NO_PROXY=model-gateway,controlled-web-proxy,127.0.0.1,localhost `
        --entrypoint sh `
        qwen-eval/opencode:0.0.0-beta-17898 `
        -c 'while :; do sleep 3600; done' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to start the controlled-web agent smoke container.' }

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $modelAliasResponse = (& docker.exe exec $agentContainer `
            curl --fail --silent --max-time 2 http://model-gateway:18081 2>$null).Trim()
        if ($LASTEXITCODE -eq 0 -and $modelAliasResponse -eq 'model-alias-ok') {
            break
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($modelAliasResponse -ne 'model-alias-ok') {
        throw 'Internal service-alias resolution failed in controlled-web mode.'
    }

    $resolverConfiguration = @(docker.exe exec $agentContainer cat /etc/resolv.conf)
    $resolverText = $resolverConfiguration -join "`n"
    if (
        $LASTEXITCODE -ne 0 -or
        $resolverText -notmatch 'nameserver 127\.0\.0\.11' -or
        $resolverText -notmatch 'ExtServers: \[127\.0\.0\.1\]'
    ) {
        throw "Agent DNS is not fail-closed: $($resolverConfiguration -join '; ')"
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & docker.exe exec $agentContainer `
            getent hosts example.com 2>$null | Out-Null
        $externalDnsExitCode = $LASTEXITCODE
        & docker.exe exec $agentContainer `
            curl --noproxy '*' --silent --connect-timeout 2 --max-time 3 `
            http://93.184.216.35 2>$null | Out-Null
        $directExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($externalDnsExitCode -eq 0) { throw 'Agent unexpectedly resolved external DNS directly.' }
    if ($directExitCode -eq 0) { throw 'Agent unexpectedly reached the test egress target directly.' }

    $targetDeadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $httpStatus = Get-ProxyStatus -Url 'http://93.184.216.35/'
        $httpsStatus = Get-ProxyStatus -Url 'https://93.184.216.35/' -Insecure
        if ($httpStatus -eq '200' -and $httpsStatus -eq '200') {
            break
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $targetDeadline)
    if ($httpStatus -ne '200' -or $httpsStatus -ne '200') {
        & docker.exe logs $proxyContainer 2>&1 | Out-Host
        & docker.exe logs $publicTargetContainer 2>&1 | Out-Host
        throw "Public HTTP/HTTPS proxy path failed: http=$httpStatus https=$httpsStatus"
    }

    $blockedCases = [ordered]@{
        localhost = 'http://127.0.0.1/'
        private = 'http://10.0.0.1/'
        metadata = 'http://169.254.169.254/latest/meta-data/'
        azure_platform = 'http://168.63.129.16/'
        configured_runpod_host = 'https://93.184.216.34/'
        http_alternate_port = 'http://93.184.216.35:8080/'
        connect_alternate_port = 'https://93.184.216.35:444/'
        docker_host = 'http://host.docker.internal/'
        onion = 'http://hidden.onion/'
    }
    foreach ($case in $blockedCases.GetEnumerator()) {
        $status = Get-ProxyStatus -Url $case.Value -Insecure
        if ($status -ne '403') {
            throw "Controlled-web policy did not block $($case.Key): HTTP $status"
        }
    }

    $proxyInspection = @(& docker.exe container inspect $proxyContainer) -join [Environment]::NewLine
    $parsedProxyInspection = $proxyInspection | ConvertFrom-Json
    if ($parsedProxyInspection -is [Array]) {
        if ($parsedProxyInspection.Count -ne 1) {
            throw 'Docker returned an ambiguous proxy inspection.'
        }
        $proxyRecord = $parsedProxyInspection[0]
    }
    else {
        $proxyRecord = $parsedProxyInspection
    }
    $proxyUid = (& docker.exe exec $proxyContainer id -u).Trim()
    $proxyCapabilities = (& docker.exe exec $proxyContainer `
        awk '/CapEff/{print $2}' /proc/self/status).Trim()
    $proxyNetworks = @($proxyRecord.NetworkSettings.Networks.PSObject.Properties.Name | Sort-Object)
    $expectedNetworks = @($internalNetwork, $egressNetwork) | Sort-Object
    if ($proxyUid -ne '10002' -or $proxyCapabilities -ne '0000000000000000') {
        throw "Proxy privilege boundary failed: uid=$proxyUid caps=$proxyCapabilities"
    }
    if ($proxyRecord.HostConfig.ReadonlyRootfs -ne $true) {
        throw 'Proxy root filesystem is writable.'
    }
    $mountProperty = $proxyRecord.PSObject.Properties['Mounts']
    if ($null -eq $mountProperty -or @($mountProperty.Value).Count -ne 0) {
        throw 'Proxy unexpectedly has mounts or omitted mount attestation.'
    }
    $publishedPorts = $proxyRecord.NetworkSettings.Ports
    if (
        $null -ne $publishedPorts -and
        @(
            $publishedPorts.PSObject.Properties |
                Where-Object { $null -ne $_.Value }
        ).Count -ne 0
    ) {
        throw 'Proxy unexpectedly publishes a host port.'
    }
    if (Compare-Object -ReferenceObject $expectedNetworks -DifferenceObject $proxyNetworks) {
        throw "Proxy network boundary failed: $($proxyNetworks -join ', ')"
    }
    $proxyEnvironment = @($proxyRecord.Config.Env)
    if (
        $proxyEnvironment -match 'RUNPOD_API|API_KEY|PASSWORD|TOKEN|SSH_' -or
        $proxyEnvironment -notcontains 'CONTROLLED_WEB_DENY_HOSTS=93.184.216.34'
    ) {
        throw 'Proxy environment contains a secret or lacks the exact dynamic host denylist.'
    }

    Write-Host "Controlled HTTP: $httpStatus; controlled HTTPS: $httpsStatus"
    Write-Host 'Blocked: localhost, private, metadata, Azure platform, current host, special names and alternate ports.'
    Write-Host 'Direct DNS and direct egress: blocked; internal model-gateway alias: reachable.'
    Write-Host "Proxy UID: $proxyUid; capabilities: $proxyCapabilities; mounts: 0; published ports: 0"
    Write-Host 'controlled-web-v1 smoke: OK'
}
finally {
    foreach ($containerName in $createdContainers) {
        if (-not $containerName.StartsWith('qwen-controlled-', [StringComparison]::Ordinal)) {
            throw "Refusing unsafe smoke-container cleanup: $containerName"
        }
        & docker.exe container rm --force $containerName 2>$null | Out-Null
    }
    foreach ($networkName in $createdNetworks) {
        if (-not $networkName.StartsWith('qwen-controlled-', [StringComparison]::Ordinal)) {
            throw "Refusing unsafe smoke-network cleanup: $networkName"
        }
        & docker.exe network rm $networkName 2>$null | Out-Null
    }
}

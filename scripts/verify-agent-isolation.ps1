param([ValidateRange(1024, 65535)][int]$Port = 14096)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) {
    throw 'Docker Desktop is required.'
}
$listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
if ($listener) {
    throw "Isolation smoke port $Port is already in use."
}

$projectRoot = (Split-Path -Parent $PSScriptRoot)
foreach ($imageBuild in @(
    @('agent/Dockerfile.opencode', 'qwen-eval/opencode:0.0.0-beta-17898'),
    @('agent/Dockerfile.ui-proxy', 'qwen-eval/ui-proxy:1'),
    @('agent/Dockerfile.gateway', 'qwen-eval/model-gateway:1')
)) {
    docker build --file (Join-Path $projectRoot $imageBuild[0]) --tag $imageBuild[1] (Join-Path $projectRoot 'agent') | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to build isolation image $($imageBuild[1])."
    }
}

$suffix = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$agentContainer = "qwen-eval-opencode-smoke-$suffix"
$proxyContainer = "qwen-eval-proxy-smoke-$suffix"
$modelAliasContainer = "qwen-eval-model-alias-smoke-$suffix"
$internalNetwork = "qwen-eval-internal-smoke-$suffix"
$ingressNetwork = "qwen-eval-ingress-smoke-$suffix"
$stateVolume = "qwen-eval-state-smoke-$suffix"
$configVolume = "qwen-eval-config-smoke-$suffix"
$cacheVolume = "qwen-eval-cache-smoke-$suffix"
$password = 'isolation-smoke-password'
$htpasswdPath = Join-Path ([IO.Path]::GetTempPath()) "qwen-eval-htpasswd-smoke-$suffix"
$passwordDigest = [System.Security.Cryptography.SHA1]::Create()
try {
    $passwordHash = $passwordDigest.ComputeHash([Text.Encoding]::UTF8.GetBytes($password))
}
finally {
    $passwordDigest.Dispose()
}
[IO.File]::WriteAllText(
    $htpasswdPath,
    ('opencode:{SHA}' + [Convert]::ToBase64String($passwordHash)),
    [Text.Encoding]::ASCII
)

try {
    docker network create --internal --subnet 172.30.241.0/24 $internalNetwork | Out-Null
    docker network create $ingressNetwork | Out-Null
    docker volume create $stateVolume | Out-Null
    docker volume create $configVolume | Out-Null
    docker volume create $cacheVolume | Out-Null

    docker run --detach `
        --name $modelAliasContainer `
        --read-only `
        --network $internalNetwork `
        --network-alias model-gateway `
        --ip 172.30.241.2 `
        --cap-drop ALL `
        --security-opt no-new-privileges:true `
        --entrypoint node `
        qwen-eval/opencode:0.0.0-beta-17898 `
        -e "require('node:http').createServer((q,s)=>s.end('model-alias-ok')).listen(18081,'0.0.0.0')" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not start the internal model-alias smoke service.'
    }

    docker run --detach `
        --name $agentContainer `
        --read-only `
        --user 10001:10001 `
        --network $internalNetwork `
        --network-alias opencode `
        --dns 127.0.0.1 `
        --add-host model-gateway:172.30.241.2 `
        --cap-drop ALL `
        --security-opt no-new-privileges:true `
        --pids-limit 256 `
        --memory 4g `
        --cpus 4 `
        --tmpfs /tmp:rw,nosuid,nodev,noexec,size=256m,mode=1777 `
        --tmpfs /home/opencode/.opencode:rw,nosuid,nodev,noexec,size=32m,mode=0700,uid=10001,gid=10001 `
        --tmpfs /workspace/.runpod:rw,nosuid,nodev,noexec,size=1m,mode=0700,uid=10001,gid=10001 `
        --tmpfs /workspace/cache:rw,nosuid,nodev,noexec,size=1m,mode=0700,uid=10001,gid=10001 `
        --tmpfs /workspace/artifacts:rw,nosuid,nodev,noexec,size=1m,mode=0700,uid=10001,gid=10001 `
        --tmpfs /workspace/results:rw,nosuid,nodev,noexec,size=1m,mode=0700,uid=10001,gid=10001 `
        --mount "type=bind,source=$projectRoot,target=/workspace" `
        --mount "type=volume,source=$stateVolume,target=/home/opencode/.local/share" `
        --mount "type=volume,source=$configVolume,target=/home/opencode/.config" `
        --mount "type=volume,source=$cacheVolume,target=/home/opencode/.cache" `
        --env LLAMACPP_BASE_URL=http://model-gateway:18081/v1 `
        --env OPENCODE_SERVER_USERNAME=opencode `
        --env OPENCODE_SERVER_PASSWORD=nonsecret-internal-v1 `
        --workdir /workspace/agent-workspace `
        qwen-eval/opencode:0.0.0-beta-17898 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not start the agent smoke container.'
    }

    docker create `
        --name $proxyContainer `
        --read-only `
        --network $internalNetwork `
        --publish "127.0.0.1:$($Port):4097" `
        --cap-drop ALL `
        --security-opt no-new-privileges:true `
        --pids-limit 32 `
        --memory 128m `
        --cpus 0.25 `
        --tmpfs /tmp:rw,nosuid,nodev,noexec,size=8m,mode=1777 `
        --tmpfs /var/cache/nginx:rw,nosuid,nodev,noexec,size=32m,mode=0700,uid=101,gid=101 `
        --mount "type=bind,source=$htpasswdPath,target=/run/secrets/opencode_htpasswd,readonly" `
        qwen-eval/ui-proxy:1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create the UI ingress smoke container.'
    }
    docker network connect $ingressNetwork $proxyContainer
    docker start $proxyContainer | Out-Null

    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        try {
            $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("opencode:$password"))
            $response = Invoke-WebRequest `
                -Uri "http://127.0.0.1:$Port" `
                -Headers @{ Authorization = "Basic $token" } `
                -UseBasicParsing `
                -TimeoutSec 3
            if ($response.StatusCode -eq 200) {
                break
            }
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    if ([DateTime]::UtcNow -ge $deadline) {
        Write-Warning "Agent state: $(docker inspect --format '{{.State.Status}}/{{.State.ExitCode}} {{json .NetworkSettings.Networks}}' $agentContainer)"
        Write-Warning "Proxy state: $(docker inspect --format '{{.State.Status}}/{{.State.ExitCode}} {{json .NetworkSettings.Networks}}' $proxyContainer)"
        $ErrorActionPreference = 'Continue'
        docker exec $agentContainer curl --verbose --max-time 3 --user opencode:nonsecret-internal-v1 http://127.0.0.1:4096/ 2>&1 | Write-Warning
        docker exec $proxyContainer curl --verbose --max-time 3 --user opencode:nonsecret-internal-v1 http://opencode:4096/ 2>&1 | Write-Warning
        $ErrorActionPreference = 'Stop'
        docker logs $agentContainer
        docker logs $proxyContainer
        throw 'OpenCode smoke UI was not reachable through the ingress-only proxy.'
    }

    $uid = (docker exec $agentContainer id -u).Trim()
    if ($LASTEXITCODE -ne 0 -or $uid -ne '10001') {
        throw "Agent container has unexpected UID: $uid"
    }
    $workingDirectory = (docker exec $agentContainer pwd).Trim()
    if ($LASTEXITCODE -ne 0 -or $workingDirectory -ne '/workspace/agent-workspace') {
        throw "Agent has unexpected working directory: $workingDirectory"
    }
    $agentEnvironment = @(docker exec $agentContainer env)
    $agentPasswordEntries = @($agentEnvironment -match '^OPENCODE_SERVER_PASSWORD=')
    if (
        $agentPasswordEntries.Count -ne 1 -or
        $agentPasswordEntries[0] -ne 'OPENCODE_SERVER_PASSWORD=nonsecret-internal-v1'
    ) {
        throw 'The agent environment does not contain exactly the non-secret internal OpenCode credential.'
    }
    docker exec $agentContainer test -e /var/run/docker.sock
    if ($LASTEXITCODE -eq 0) { throw 'Docker socket is exposed to the agent.' }
    docker exec $agentContainer test -e /workspace/.runpod/api-key
    if ($LASTEXITCODE -eq 0) { throw 'RunPod API key is exposed to the agent.' }
    $maskedState = docker exec $agentContainer find /workspace/.runpod -mindepth 1 -print -quit
    if ($LASTEXITCODE -ne 0 -or $maskedState) { throw 'The .runpod mask is missing or not empty.' }
    foreach ($maskedDirectory in @('cache', 'artifacts', 'results')) {
        $maskedContent = docker exec $agentContainer find "/workspace/$maskedDirectory" -mindepth 1 -print -quit
        if ($LASTEXITCODE -ne 0 -or $maskedContent) {
            throw "The $maskedDirectory mask is missing or not empty."
        }
    }
    $ErrorActionPreference = 'Continue'
    docker exec $agentContainer touch /etc/agent-must-not-write 2>$null
    $rootWriteExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($rootWriteExitCode -eq 0) { throw 'Agent root filesystem is unexpectedly writable.' }
    docker exec $agentContainer touch /workspace/.container-write-smoke
    if ($LASTEXITCODE -ne 0) { throw 'Agent cannot write to the authorized project directory.' }
    docker exec $agentContainer rm /workspace/.container-write-smoke
    $resolverConfiguration = @(docker exec $agentContainer cat /etc/resolv.conf)
    $resolverText = $resolverConfiguration -join "`n"
    if (
        $LASTEXITCODE -ne 0 -or
        $resolverText -notmatch 'nameserver 127\.0\.0\.11' -or
        $resolverText -notmatch 'ExtServers: \[127\.0\.0\.1\]'
    ) {
        throw "Agent DNS is not fail-closed: $($resolverConfiguration -join '; ')"
    }
    $modelAliasResponse = (docker exec $agentContainer curl --fail --silent --max-time 5 http://model-gateway:18081).Trim()
    if ($LASTEXITCODE -ne 0 -or $modelAliasResponse -ne 'model-alias-ok') {
        throw 'The fail-closed DNS setup broke the internal model-gateway alias.'
    }
    $ErrorActionPreference = 'Continue'
    docker exec $agentContainer getent hosts example.com 2>$null | Out-Null
    $externalDnsExitCode = $LASTEXITCODE
    docker exec $agentContainer curl --fail --silent --connect-timeout 3 --max-time 5 http://93.184.216.34 2>$null | Out-Null
    $internetExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($externalDnsExitCode -eq 0) { throw 'Agent unexpectedly resolved an external DNS name.' }
    if ($internetExitCode -eq 0) { throw 'Agent unexpectedly reached the public Internet.' }
    $capabilities = (docker exec $agentContainer awk '/CapEff/{print $2}' /proc/self/status).Trim()
    if ($LASTEXITCODE -ne 0 -or $capabilities -ne '0000000000000000') {
        throw "Agent retained Linux capabilities: $capabilities"
    }

    $proxyUid = (docker exec $proxyContainer id -u).Trim()
    $proxyCapabilities = (docker exec $proxyContainer awk '/CapEff/{print $2}' /proc/self/status).Trim()
    if (
        $LASTEXITCODE -ne 0 -or
        $proxyUid -ne '101' -or
        $proxyCapabilities -ne '0000000000000000'
    ) {
        throw "UI proxy privilege boundary failed: uid=$proxyUid caps=$proxyCapabilities"
    }
    $proxyEnvironment = @(docker exec $proxyContainer env)
    if (
        @(
            $proxyEnvironment |
                Where-Object { $_ -match '(?i)(PASSWORD|TOKEN|API_KEY|RUNPOD|SSH_)' }
        ).Count -ne 0
    ) {
        throw 'UI proxy environment unexpectedly contains a credential-like value.'
    }
    $proxyMounts = @(
        (docker inspect --format '{{json .Mounts}}' $proxyContainer) |
            ConvertFrom-Json
    )
    if (
        $LASTEXITCODE -ne 0 -or
        $proxyMounts.Count -ne 1 -or
        [string]$proxyMounts[0].Destination -ne '/run/secrets/opencode_htpasswd' -or
        $proxyMounts[0].RW -ne $false
    ) {
        throw 'UI proxy does not have exactly the read-only GUI hash mount.'
    }

    $agentNetworks = docker inspect --format '{{json .NetworkSettings.Networks}}' $agentContainer
    $proxyNetworks = docker inspect --format '{{json .NetworkSettings.Networks}}' $proxyContainer
    Write-Host "OpenCode UI: HTTP $($response.StatusCode)"
    Write-Host "Agent UID: $uid; effective capabilities: $capabilities; workdir: $workingDirectory"
    Write-Host "UI proxy UID: $proxyUid; effective capabilities: $proxyCapabilities; credential mounts: 1 hash only"
    Write-Host 'Agent DNS: external lookup blocked; internal model-gateway alias reachable.'
    Write-Host "Agent networks: $agentNetworks"
    Write-Host "Ingress networks: $proxyNetworks"
    Write-Host 'Agent isolation smoke: OK'
}
finally {
    docker container rm --force $proxyContainer $agentContainer $modelAliasContainer 2>$null | Out-Null
    docker network rm $ingressNetwork $internalNetwork 2>$null | Out-Null
    docker volume rm $stateVolume $configVolume $cacheVolume 2>$null | Out-Null
    $writeMarker = Join-Path $projectRoot '.container-write-smoke'
    if (Test-Path -LiteralPath $writeMarker -PathType Leaf) {
        Remove-Item -LiteralPath $writeMarker -Force
    }
    if (Test-Path -LiteralPath $htpasswdPath -PathType Leaf) {
        Remove-Item -LiteralPath $htpasswdPath -Force
    }
}

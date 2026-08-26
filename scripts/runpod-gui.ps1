param(
    [ValidateRange(1024, 65535)][int]$Port = 4096,
    [switch]$Restart,
    [switch]$NoBrowser,
    [switch]$ControlledWeb
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RunPod.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ControlledWeb.Common.psm1') -Force

foreach ($command in @('docker.exe')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw 'Docker Desktop is required for the isolated agent GUI.'
    }
}
& docker.exe compose version | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Compose is not available. Start or update Docker Desktop.'
}
$dockerOs = (& docker.exe info --format '{{.OSType}}' 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $dockerOs -ne 'linux') {
    throw 'Docker Desktop must be running with Linux containers.'
}

$session = Get-RunPodSession
Assert-RunPodSession -Session $session
$projectRoot = Get-QwenProjectRoot
$composePath = Join-Path $projectRoot 'agent\compose.yaml'
$controlledWebComposePath = Join-Path $projectRoot 'agent\compose.controlled-web.yaml'
$apiKeyPath = Get-RunPodApiKeyPath
$knownHostsPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh\known_hosts'
$webPasswordPath = New-OpenCodeWebPassword
$webPasswordHashPath = Join-Path (Get-RunPodStateDirectory) 'opencode.htpasswd'

$requiredFiles = @($composePath, $apiKeyPath, $session.IdentityFile, $knownHostsPath)
if ($ControlledWeb) {
    $requiredFiles += $controlledWebComposePath
}
foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required file for the isolated GUI is missing: $requiredFile"
    }
}
$webPassword = (Get-Content -LiteralPath $webPasswordPath -Raw -Encoding ascii).Trim()
if ([string]::IsNullOrWhiteSpace($webPassword)) {
    throw "OpenCode Web password is empty: $webPasswordPath"
}
$sha1 = [System.Security.Cryptography.SHA1]::Create()
try {
    $webPasswordDigest = $sha1.ComputeHash([Text.Encoding]::UTF8.GetBytes($webPassword))
}
finally {
    $sha1.Dispose()
}
$htpasswdRecord = 'opencode:{SHA}' + [Convert]::ToBase64String($webPasswordDigest)
[IO.File]::WriteAllText(
    $webPasswordHashPath,
    $htpasswdRecord,
    [Text.Encoding]::ASCII
)
Protect-RunPodSecretFile -Path $webPasswordHashPath

$requestedNetworkMode = if ($ControlledWeb) { 'controlled-web-v1' } else { 'offline-v1' }
$stackRunning = Test-OpenCodeWebProcess -Session $session

if ($Restart) {
    Stop-OpenCodeWeb -Session $session
    $session = Get-RunPodSession
}
elseif ($stackRunning) {
    if ([int]$session.OpenCodePort -ne $Port) {
        throw "OpenCode already runs on port $($session.OpenCodePort). Use -Restart to change it."
    }
    $currentNetworkMode = Get-ControlledWebRuntimeMode -ExpectedDenyHost ([string]$session.SshHost)
    if ($currentNetworkMode -ne $requestedNetworkMode) {
        throw "OpenCode already runs in network mode '$currentNetworkMode'. Use -Restart to select '$requestedNetworkMode'."
    }
}
else {
    Remove-ControlledWebResources
    $listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    if ($listener) {
        throw "Local GUI port $Port is already in use by another process."
    }
}

$runtimeConfigResult = Write-OpenCodeRuntimeConfig -ActiveModel ([string]$session.ActiveModel)
$activeOpenCodeModel = [string]$runtimeConfigResult.ActiveOpenCodeModel

$composeEnvironment = [ordered]@{
    QWEN_PROJECT_ROOT = (Resolve-Path -LiteralPath $projectRoot).Path
    RUNPOD_IDENTITY_FILE = (Resolve-Path -LiteralPath $session.IdentityFile).Path
    RUNPOD_KNOWN_HOSTS_FILE = (Resolve-Path -LiteralPath $knownHostsPath).Path
    RUNPOD_API_KEY_FILE = (Resolve-Path -LiteralPath $apiKeyPath).Path
    RUNPOD_SSH_HOST = [string]$session.SshHost
    RUNPOD_SSH_PORT = [string]$session.SshPort
    RUNPOD_SSH_USER = [string]$session.SshUser
    RUNPOD_REMOTE_PORT = [string]$session.RemotePort
    OPENCODE_WEB_PORT = [string]$Port
    OPENCODE_HTPASSWD_FILE = (Resolve-Path -LiteralPath $webPasswordHashPath).Path
}
$previousEnvironment = @{}
$composeArguments = @(
    'compose',
    '--project-name', 'qwen-eval-agent',
    '--file', $composePath
)
if ($ControlledWeb) {
    $composeArguments += @(
        '--file', $controlledWebComposePath,
        '--profile', 'controlled-web-v1'
    )
}
try {
    foreach ($entry in $composeEnvironment.GetEnumerator()) {
        $previousEnvironment[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    & docker.exe @composeArguments up --detach --build --remove-orphans --wait --wait-timeout 180
    if ($LASTEXITCODE -ne 0) {
        $composeExitCode = $LASTEXITCODE
        & docker.exe @composeArguments logs --tail 100
        throw "The isolated OpenCode stack failed to start (exit code $composeExitCode)."
    }
}
finally {
    foreach ($entry in $composeEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $previousEnvironment[$entry.Key], 'Process')
    }
}

$attestedNetworkMode = Get-ControlledWebRuntimeMode -ExpectedDenyHost ([string]$session.SshHost)
if ($attestedNetworkMode -ne $requestedNetworkMode) {
    throw "Container-attested network mode '$attestedNetworkMode' does not match requested mode '$requestedNetworkMode'."
}
$session | Add-Member -NotePropertyName OpenCodePort -NotePropertyValue $Port -Force
$session | Add-Member -NotePropertyName OpenCodeRuntime -NotePropertyValue 'isolated-docker' -Force
$session | Add-Member -NotePropertyName OpenCodeModel -NotePropertyValue $activeOpenCodeModel -Force
$session | Add-Member -NotePropertyName OpenCodeNetworkMode -NotePropertyValue $requestedNetworkMode -Force
Save-RunPodSession -Session $session

$url = "http://127.0.0.1:$Port"
$authorization = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("opencode:$webPassword"))
$healthHeaders = @{ Authorization = "Basic $authorization" }
$deadline = [DateTime]::UtcNow.AddSeconds(30)
do {
    try {
        $response = Invoke-WebRequest -Uri $url -Headers $healthHeaders -UseBasicParsing -TimeoutSec 3
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
            break
        }
    }
    catch {
        Start-Sleep -Milliseconds 500
    }
} while ([DateTime]::UtcNow -lt $deadline)
if ([DateTime]::UtcNow -ge $deadline) {
    throw "OpenCode Web did not become reachable on $url. Run 'docker logs qwen-eval-opencode' for details."
}

if (-not $NoBrowser) {
    $authenticatedUrl = "http://opencode:$([Uri]::EscapeDataString($webPassword))@127.0.0.1:$Port/"
    Start-Process $authenticatedUrl | Out-Null
}

Write-Host "OpenCode Web: $url"
Write-Host "Active model: $($session.ActiveModel) ($($session.ActiveAlias)); OpenCode profile: $activeOpenCodeModel"
if ($ControlledWeb) {
    Write-Host 'Network mode: controlled-web-v1; public HTTP/HTTPS through the filtered proxy, non-public and reserved targets blocked.'
    Write-Host 'Isolation: non-root agent container, project-only mount, no direct Internet route, no Docker socket, no host secrets.'
    Write-Warning 'Public HTTPS can transmit project data. Enable this mode only for tasks whose external destinations and data scope you authorize.'
}
else {
    Write-Host 'Network mode: offline-v1.'
    Write-Host 'Isolation: non-root agent container, project-only mount, no Internet, no Docker socket, no host secrets.'
}
Write-Host 'Agent working directory: /workspace/agent-workspace (the repository remains mounted at /workspace).'
Write-Host 'Files and screenshots can be attached by picker, paste or drag-and-drop.'

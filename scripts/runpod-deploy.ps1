param(
    [Parameter(Mandatory)][Alias('Host')][string]$SshHost,
    [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$SshPort,
    [string]$SshUser = 'root',
    [Parameter(Mandatory)][string]$IdentityFile,
    [Parameter(Mandatory)][string]$PodId,
    [Parameter(Mandatory)][string]$DeploymentId,
    [Parameter(Mandatory)][string]$DeploymentProfileId,
    [Parameter(Mandatory)][string]$DeploymentPlanSha256,
    [Parameter(Mandatory)][string]$ProvisioningStatePath,
    [Parameter(Mandatory)][string]$ExpectedGpuName,
    [Parameter(Mandatory)][ValidateRange(80000, 90000)][int]$ExpectedGpuMemoryMiB,
    [Parameter(Mandatory)][string]$ExpectedComputeCapability,
    [Parameter(Mandatory)][string]$ExpectedCudaRelease,
    [ValidateSet('uncensored-q6', 'uncensored-q8', 'uncensored-q4', 'whitehat-q4')][string]$Model = 'uncensored-q6',
    [bool]$DownloadAll = $false,
    [ValidateSet('Hub', 'PreferLocal', 'LocalOnly')][string]$ModelSource = 'Hub',
    [string]$LocalModelRoot,
    [bool]$LaunchGui = $false,
    [ValidateSet('Offline', 'ControlledWeb')][string]$GuiNetworkMode = 'Offline',
    [ValidateRange(1024, 65535)][int]$LocalPort = 18080,
    [string]$RemoteDir = '/workspace/qwen-eval'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RunPod.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ModelBackup.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RemoteModelActivation.Common.psm1') -Force
$projectRoot = Get-QwenProjectRoot

if (
    $PodId -notmatch '^[a-z0-9]{8,32}$' -or
    $DeploymentId -notmatch '^a100-pcie-[a-z0-9-]{8,80}$' -or
    $DeploymentProfileId -ne 'a100-pcie-80gb-q6-v1' -or
    $DeploymentPlanSha256 -notmatch '^[0-9a-f]{64}$' -or
    $ExpectedGpuName -ne 'NVIDIA A100 80GB PCIe' -or
    $ExpectedGpuMemoryMiB -ne 80000 -or
    $ExpectedComputeCapability -ne '8.0' -or
    $ExpectedCudaRelease -ne '12.4' -or
    $Model -ne 'uncensored-q6' -or
    $DownloadAll
) {
    throw 'Deployment arguments do not match the immutable A100 PCIe Q6 contract.'
}

$expectedProvisioningStatePath = Join-Path $projectRoot ".runpod\deployments\$DeploymentProfileId\state.json"
$resolvedProvisioningStatePath = (Resolve-Path -LiteralPath $ProvisioningStatePath -ErrorAction Stop).Path
$resolvedExpectedProvisioningStatePath = (Resolve-Path -LiteralPath $expectedProvisioningStatePath -ErrorAction Stop).Path
if (-not [string]::Equals(
    $resolvedProvisioningStatePath,
    $resolvedExpectedProvisioningStatePath,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'Provisioning state path is outside the immutable deployment profile.'
}
$provisioningState = Get-Content -LiteralPath $resolvedProvisioningStatePath -Raw -Encoding utf8 | ConvertFrom-Json
if (
    [string]$provisioningState.deployment_id -ne $DeploymentId -or
    [string]$provisioningState.deployment_profile_id -ne $DeploymentProfileId -or
    [string]$provisioningState.plan_sha256 -ne $DeploymentPlanSha256 -or
    [string]$provisioningState.pod_id -ne $PodId -or
    [string]$provisioningState.outcome -ne 'bootstrapping' -or
    [string]$provisioningState.ssh_host -ne $SshHost -or
    [int]$provisioningState.ssh_port -ne $SshPort
) {
    throw 'Provisioning state does not bind the requested pod, plan, profile, and SSH endpoint.'
}

foreach ($command in @('ssh.exe', 'scp.exe')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command is missing: $command"
    }
}

$resolvedIdentity = (Resolve-Path -LiteralPath $IdentityFile).Path
$modelRecord = Get-RunPodModel -Model $Model
$session = [pscustomobject]@{
    SshHost = $SshHost
    SshPort = $SshPort
    SshUser = $SshUser
    IdentityFile = $resolvedIdentity
    RemoteDir = $RemoteDir
    RemotePort = 8080
    LocalPort = $LocalPort
    ActiveModel = $Model
    ActiveAlias = $modelRecord.alias
    PodId = $PodId
    DeploymentId = $DeploymentId
    DeploymentProfileId = $DeploymentProfileId
    DeploymentPlanSha256 = $DeploymentPlanSha256
    LifecycleStatus = 'bootstrapping'
    GpuName = $ExpectedGpuName
    GpuCount = 1
    GpuMemoryMiB = $null
    ComputeCapability = $ExpectedComputeCapability
    CudaRelease = $ExpectedCudaRelease
    ModelSource = $null
    ModelSourcePolicy = 'content-addressed-hub-or-verified-local-v1'
    LocalModelManifestSha256 = $null
    LocallySeededModels = @()
    LlamaBuildInfo = $null
    QualifiedAtUtc = $null
    TunnelPid = $null
    OpenCodePort = $null
    OpenCodeRuntime = $null
}
Assert-RunPodSession -Session $session

Write-Host 'Checking full SSH access to the RunPod...'
Invoke-RunPodSsh -Session $session -RemoteCommand "test -d /workspace && mkdir -p '$RemoteDir/config' '$RemoteDir/state'"

Write-Host 'Uploading the immutable deployment scripts and model manifest...'
$remoteRunPodStage = "$RemoteDir/runpod.next"
$remoteRunPodPrevious = "$RemoteDir/runpod.previous"
Invoke-RunPodSsh -Session $session -RemoteCommand "rm -rf '$remoteRunPodStage'"
Copy-RunPodItem -Session $session -LocalPath (Join-Path $projectRoot 'runpod') -RemotePath $remoteRunPodStage -Recurse
Copy-RunPodItem -Session $session -LocalPath (Join-Path $projectRoot 'config\models.json') -RemotePath "$RemoteDir/config/models.json.next"
Invoke-RunPodSsh -Session $session -RemoteCommand "test -f '$remoteRunPodStage/bootstrap.sh' && test -f '$remoteRunPodStage/hardware-gate.sh' && find '$remoteRunPodStage' -type f -name '*.sh' -exec chmod 755 {} + && rm -rf '$remoteRunPodPrevious' && if test -d '$RemoteDir/runpod'; then mv '$RemoteDir/runpod' '$remoteRunPodPrevious'; fi && mv '$remoteRunPodStage' '$RemoteDir/runpod' && mv '$RemoteDir/config/models.json.next' '$RemoteDir/config/models.json'"

Write-Host 'Qualifying the exact A100 PCIe hardware before package installation or model download...'
$minimumGpuMemoryMiB = $ExpectedGpuMemoryMiB
$minimumWorkspaceBytes = 80000000000
$hardwareCommand = "bash '$RemoteDir/runpod/hardware-gate.sh' '$ExpectedGpuName' '$ExpectedComputeCapability' '$ExpectedCudaRelease' '$minimumGpuMemoryMiB' '$minimumWorkspaceBytes' '$RemoteDir/state/hardware.json'"
$hardwareOutput = @(Invoke-RunPodSshBounded -Session $session -RemoteCommand $hardwareCommand -TimeoutSeconds 60)
if ($hardwareOutput.Count -lt 1) {
    throw 'A100 hardware gate returned no qualification record.'
}
$hardware = $hardwareOutput[-1] | ConvertFrom-Json
if (
    -not $hardware.qualified -or
    [string]$hardware.gpu_name -ne $ExpectedGpuName -or
    [int]$hardware.gpu_count -ne 1 -or
    [int]$hardware.gpu_memory_mib -lt $minimumGpuMemoryMiB -or
    [string]$hardware.compute_capability -ne $ExpectedComputeCapability -or
    [string]$hardware.cuda_release -ne $ExpectedCudaRelease
) {
    throw 'Remote hardware qualification record does not match the A100 PCIe contract.'
}
$session.GpuMemoryMiB = [int]$hardware.gpu_memory_mib

$backup = $null
$effectiveModelSource = 'hub'
if ($ModelSource -eq 'Hub') {
    if (-not [string]::IsNullOrWhiteSpace($LocalModelRoot)) {
        throw '-LocalModelRoot cannot be combined with -ModelSource Hub.'
    }
}
else {
    $backupRequired = $ModelSource -eq 'LocalOnly' -or -not [string]::IsNullOrWhiteSpace($LocalModelRoot)
    $resolvedBackupRoot = Resolve-QwenModelBackupRoot `
        -BackupRoot $LocalModelRoot `
        -ProjectRoot $projectRoot `
        -Required:$backupRequired
    if ($null -ne $resolvedBackupRoot) {
        Write-Host 'Verifying the external local model backup before upload...'
        $backup = Assert-QwenModelBackup `
            -ProjectRoot $projectRoot `
            -BackupRoot $resolvedBackupRoot `
            -Model $Model
        $effectiveModelSource = 'local-only'
    }
    elseif ($ModelSource -eq 'LocalOnly') {
        throw 'Local-only deployment requires a complete verified model backup.'
    }
}

if ($null -ne $backup) {
    [void](Invoke-QwenRemoteModelActivation `
        -Session $session `
        -ProjectRoot $projectRoot `
        -RemoteDir $RemoteDir `
        -Model $Model `
        -Backup $backup)
}
$session.ModelSource = $effectiveModelSource
if ($null -ne $backup) {
    $session.LocalModelManifestSha256 = [string]$backup.ManifestSha256
    $session.LocallySeededModels = @($Model)
}

$apiKeyPath = New-RunPodApiKey
Copy-RunPodItem -Session $session -LocalPath $apiKeyPath -RemotePath "$RemoteDir/state/api-key"
Invoke-RunPodSsh -Session $session -RemoteCommand "chmod 600 '$RemoteDir/state/api-key'"

$bootstrapCommand = "bash '$RemoteDir/runpod/bootstrap.sh' --model '$Model' --model-source '$effectiveModelSource'"
if ($DownloadAll) {
    $bootstrapCommand += ' --download-all'
}
Write-Host 'Preparing CUDA runtime, llama.cpp, model files and server. This can take a while on the first run...'
Invoke-RunPodSsh -Session $session -RemoteCommand $bootstrapCommand

$bootstrapOutput = @(
    Invoke-RunPodSshBounded `
        -Session $session `
        -RemoteCommand "jq -ce 'objects' '$RemoteDir/state/bootstrap.json'" `
        -TimeoutSeconds 30
)
if (
    $bootstrapOutput.Count -ne 1 -or
    [string]::IsNullOrWhiteSpace([string]$bootstrapOutput[0])
) {
    throw 'Remote bootstrap state did not contain exactly one compact JSON object.'
}
try {
    $bootstrapJson = [string]$bootstrapOutput[0]
    $bootstrap = $bootstrapJson | ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "Remote bootstrap state is not valid JSON: $($_.Exception.Message)"
}
if (
    [string]$bootstrap.build_profile -ne 'api_only_v1' -or
    [string]$bootstrap.selected_model -ne $Model -or
    [string]$bootstrap.model_source -ne $effectiveModelSource -or
    [string]$bootstrap.cuda_architectures -ne '80' -or
    [string]$bootstrap.llama_cpp_revision -notlike 'bb4caa754*'
) {
    throw 'Remote bootstrap record does not match the pinned A100 CUDA/model/build contract.'
}
$runtimeGateOutput = @(
    Invoke-RunPodSshBounded `
        -Session $session `
        -RemoteCommand "bash '$RemoteDir/runpod/runtime-gate.sh' 30000" `
        -TimeoutSeconds 30
)
if ($runtimeGateOutput.Count -ne 1) {
    throw 'The qualified llama-server runtime gate did not return exactly one JSON object.'
}
try {
    $runtimeGate = [string]$runtimeGateOutput[0] | ConvertFrom-Json -ErrorAction Stop
    [int64]$gpuProcessMemory = $runtimeGate.process_memory_mib
}
catch {
    throw "The qualified llama-server runtime gate returned invalid JSON: $($_.Exception.Message)"
}
$requiredRuntimeChecks = @(
    'server_binary_exact',
    'host_loopback_exact',
    'api_key_file_exact',
    'no_ui_exact',
    'context_size_exact',
    'api_only_build_profile_exact',
    'full_gpu_offload'
)
$runtimeChecksPassed = $true
foreach ($propertyName in $requiredRuntimeChecks) {
    $property = $runtimeGate.PSObject.Properties[$propertyName]
    if ($null -eq $property -or $property.Value -isnot [bool] -or -not $property.Value) {
        $runtimeChecksPassed = $false
    }
}
if ($gpuProcessMemory -lt 30000 -or -not $runtimeChecksPassed) {
    throw 'The qualified llama-server process is not fully resident on the A100 GPU.'
}

$session = Start-RunPodTunnel -Session $session
$manifest = Get-Content -LiteralPath (Join-Path $projectRoot 'config\models.json') -Raw -Encoding utf8 | ConvertFrom-Json
$session.LlamaBuildInfo = [string]$manifest.llama_cpp.expected_build_info
$session.LifecycleStatus = 'ready'
$session.QualifiedAtUtc = [DateTime]::UtcNow.ToString('o')
Save-RunPodSession -Session $session
[void](Write-OpenCodeRuntimeConfig -ActiveModel $Model)
Invoke-RunPodSsh -Session $session -RemoteCommand "rm -rf '$remoteRunPodPrevious'"

Write-Host ''
Write-Host "RunPod is ready with model $($session.ActiveModel)."
Write-Host "API URL: http://127.0.0.1:$($session.LocalPort)/v1"
Write-Host 'The generated API key is stored in .runpod/api-key and is not tracked by Git.'

if ($LaunchGui) {
    & (Join-Path $PSScriptRoot 'runpod-gui.ps1') `
        -ControlledWeb:($GuiNetworkMode -eq 'ControlledWeb')
}

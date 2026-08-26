param(
    [switch]$Execute,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedPlanSha256,
    [string]$IdentityFile,
    [ValidateSet('Hub', 'PreferLocal', 'LocalOnly')][string]$ModelSource = 'Hub',
    [string]$LocalModelRoot,
    [ValidateRange(1024, 65535)][int]$LocalPort = 18080,
    [ValidateSet('Human', 'Json')][string]$OutputFormat = 'Human'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $projectRoot 'config\runpod-a100-pcie-deployment.json'
$validatorPath = Join-Path $PSScriptRoot 'validate_runpod_deployment_manifest.py'
$providerModulePath = Join-Path $PSScriptRoot 'RunPod.Provider.psm1'
$deploymentProfileId = 'a100-pcie-80gb-q6-v1'
$deploymentDirectory = Join-Path $projectRoot ".runpod\deployments\$deploymentProfileId"
$planPath = Join-Path $deploymentDirectory 'plan.json'
$statePath = Join-Path $deploymentDirectory 'state.json'
$lockPath = Join-Path $deploymentDirectory 'execute.lock'

function Get-PythonCommand {
    foreach ($name in @('python.exe', 'python')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }
    throw 'Python 3.12 is required to validate the RunPod deployment contract.'
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
            $utf8
        )
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backupPath = "$Path.previous"
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
            [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
        else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Write-Result {
    param([Parameter(Mandatory)]$Result)

    if ($OutputFormat -eq 'Json') {
        $Result | ConvertTo-Json -Depth 16 -Compress
        return
    }
    if ($Result.mode -eq 'dry_run') {
        Write-Host 'RunPod A100 deployment is prepared offline; no provider mutation was performed.'
        Write-Host "Plan: $($Result.plan_path)"
        Write-Host "Plan SHA-256: $($Result.plan_sha256)"
        Write-Host 'Target: Secure Cloud, 1x NVIDIA A100 PCIe 80GB, Q6, 262144 context, 120 GB /workspace.'
        Write-Host 'A later start requires -Execute and this exact hash via -ExpectedPlanSha256.'
        return
    }
    Write-Host "RunPod deployment outcome: $($Result.outcome)"
    Write-Host "Pod id: $($Result.pod_id)"
    Write-Host "SSH: $($Result.ssh_host):$($Result.ssh_port)"
    Write-Host "State: $($Result.state_path)"
}

function Disable-BoundRunPodSession {
    param(
        [Parameter(Mandatory)][string]$PodId,
        [Parameter(Mandatory)][string]$PlanSha256
    )

    $sessionPath = Get-RunPodSessionPath
    if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
        return $true
    }
    try {
        $session = Get-Content -LiteralPath $sessionPath -Raw -Encoding utf8 | ConvertFrom-Json
        $sessionPodIdProperty = $session.PSObject.Properties['PodId']
        $sessionPlanProperty = $session.PSObject.Properties['DeploymentPlanSha256']
        $sessionPodId = if ($null -eq $sessionPodIdProperty) { $null } else { $sessionPodIdProperty.Value }
        $sessionPlanSha256 = if ($null -eq $sessionPlanProperty) { $null } else { $sessionPlanProperty.Value }
        if (
            -not [string]::Equals([string]$sessionPodId, $PodId, [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$sessionPlanSha256,
                $PlanSha256,
                [StringComparison]::Ordinal
            )
        ) {
            return $true
        }
        # Invalidate qualification before touching the tunnel. A failure in
        # tunnel cleanup can then never leave a ready session for a stopped Pod.
        $session | Add-Member -NotePropertyName LifecycleStatus -NotePropertyValue 'stopped_after_failure' -Force
        $session | Add-Member -NotePropertyName QualifiedAtUtc -NotePropertyValue $null -Force
        $session | Add-Member -NotePropertyName OpenCodeRuntime -NotePropertyValue $null -Force
        Save-RunPodSession -Session $session
        [void](Stop-RunPodTunnel -Session $session)
        return $true
    }
    catch {
        return $false
    }
}

function Get-OwnedRunPodCandidate {
    param(
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)][string]$ExpectedName
    )

    $candidateId = Get-RunPodPodId -Pod $Candidate
    if ([string]::IsNullOrWhiteSpace($candidateId)) {
        throw 'RunPod ownership candidate has no pod id.'
    }
    $authoritativePod = Get-RunPodPod -ApiKey $ApiKey -PodId $candidateId
    [void](Assert-RunPodPodOwnership `
        -Pod $authoritativePod `
        -ExpectedPodId $candidateId `
        -ExpectedName $ExpectedName)
    return [pscustomobject]@{
        PodId = $candidateId
        Pod = $authoritativePod
    }
}

function Get-AuthoritativeRunPodComputePrice {
    param([Parameter(Mandatory)]$Pod)

    foreach ($name in @('costPerHr', 'costPerHour')) {
        $property = $Pod.PSObject.Properties |
            Where-Object { [string]::Equals($_.Name, $name, [StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -First 1
        if ($null -ne $property -and $null -ne $property.Value) {
            return [decimal]$property.Value
        }
    }
    throw 'Authoritative RunPod pod response omitted the compute price.'
}

$python = Get-PythonCommand
& $python $validatorPath --manifest $manifestPath --plan-output $planPath --quiet
if ($LASTEXITCODE -ne 0) {
    throw "RunPod deployment manifest validation failed with exit code $LASTEXITCODE."
}

$planSha256 = (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant()
$plan = Get-Content -LiteralPath $planPath -Raw -Encoding utf8 | ConvertFrom-Json
if (-not [string]::Equals([string]$plan.api_base, 'https://rest.runpod.io/v1', [StringComparison]::Ordinal)) {
    throw 'The rendered plan does not use the pinned RunPod REST API base.'
}
if (-not [string]::Equals([string]$plan.deployment_profile_id, $deploymentProfileId, [StringComparison]::Ordinal)) {
    throw 'The rendered deployment profile id is not the approved A100 profile.'
}
if (
    [string]$plan.execution_policy.model_source_policy -ne
    'content-addressed-hub-or-verified-local-v1'
) {
    throw 'The rendered plan does not approve the content-addressed model source policy.'
}
$commonModulePath = Join-Path $PSScriptRoot 'RunPod.Common.psm1'
Import-Module $commonModulePath -Force
Import-Module (Join-Path $PSScriptRoot 'ModelBackup.Common.psm1') -Force
$runtimeConfig = Write-OpenCodeRuntimeConfig -ActiveModel ([string]$plan.workload.model_id)
if (
    [string]$runtimeConfig.ActiveOpenCodeModel -ne 'uncensored-q6-interactive-v1' -or
    [string]$runtimeConfig.Config.model -ne 'runpod/uncensored-q6-interactive-v1' -or
    [bool]$runtimeConfig.Config.providers.runpod.models.'uncensored-q6-interactive-v1'.disabled -or
    -not [bool]$runtimeConfig.Config.providers.runpod.models.'uncensored-q6'.disabled -or
    -not [bool]$runtimeConfig.Config.providers.runpod.models.'uncensored-q8'.disabled -or
    -not [bool]$runtimeConfig.Config.providers.runpod.models.'uncensored-q4'.disabled -or
    -not [bool]$runtimeConfig.Config.providers.runpod.models.'whitehat-q4'.disabled
) {
    throw 'The materialized OpenCode runtime overlay does not select only the Q6 interactive profile.'
}

if (-not $Execute) {
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanSha256)) {
        throw '-ExpectedPlanSha256 is accepted only together with -Execute.'
    }
    $dryRunResult = [ordered]@{
        operation = 'runpod.provision'
        mode = 'dry_run'
        mutation_state = 'none'
        mutation_performed = $false
        offline_ready_for_execute = $true
        provider_preflight = 'deferred_to_execute'
        plan_sha256 = $planSha256
        plan_path = $planPath
        target = $plan.target
        checks = @(
            'manifest_valid',
            'model_manifest_sha256_valid',
            'secure_cloud_exact',
            'a100_pcie_80gb_exact',
            'price_limit_1_50_exact',
            'no_template_id',
            'create_attempt_limit_one',
            'content_addressed_model_source_policy',
            'opencode_q6_interactive_overlay_ready'
        )
        blockers = @()
    }
    Write-Result -Result $dryRunResult
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ExpectedPlanSha256)) {
    throw '-Execute requires -ExpectedPlanSha256 from the offline DryRun.'
}
if (-not [string]::Equals($ExpectedPlanSha256.ToLowerInvariant(), $planSha256, [StringComparison]::Ordinal)) {
    throw "The approved plan SHA-256 does not match $planPath. No provider request was sent."
}
if ([string]::IsNullOrWhiteSpace($IdentityFile)) {
    throw '-Execute requires -IdentityFile for the public Full-SSH endpoint.'
}
$resolvedIdentity = (Resolve-Path -LiteralPath $IdentityFile -ErrorAction Stop).Path
$modelSourcePolicy = 'content-addressed-hub-or-verified-local-v1'
$effectiveModelSource = 'hub'
$resolvedLocalModelRoot = $null
if ($ModelSource -eq 'Hub') {
    if (-not [string]::IsNullOrWhiteSpace($LocalModelRoot)) {
        throw '-LocalModelRoot cannot be combined with -ModelSource Hub.'
    }
}
else {
    $backupRequired = $ModelSource -eq 'LocalOnly' -or -not [string]::IsNullOrWhiteSpace($LocalModelRoot)
    $resolvedLocalModelRoot = Resolve-QwenModelBackupRoot `
        -BackupRoot $LocalModelRoot `
        -ProjectRoot $projectRoot `
        -Required:$backupRequired
    if ($null -ne $resolvedLocalModelRoot) {
        Write-Host 'Preflighting the complete external model backup before any provider mutation...'
        [void](Assert-QwenModelBackup `
            -ProjectRoot $projectRoot `
            -BackupRoot $resolvedLocalModelRoot `
            -Model ([string]$plan.workload.model_id))
        $effectiveModelSource = 'local-only'
    }
    elseif ($ModelSource -eq 'LocalOnly') {
        throw 'Local-only deployment requires a complete verified model backup.'
    }
}
$effectiveBackupManifestSha256 = if ($null -eq $resolvedLocalModelRoot) {
    $null
}
else {
    (Get-FileHash -LiteralPath (Join-Path $projectRoot 'config\models.json') -Algorithm SHA256).Hash.ToLowerInvariant()
}
$providerApiKey = [string]$env:RUNPOD_API_KEY
if ([string]::IsNullOrWhiteSpace($providerApiKey)) {
    throw '-Execute requires RUNPOD_API_KEY. The llama-server key in .runpod/api-key is not a provider credential.'
}
$providerApiKey = $providerApiKey.Trim()

Import-Module $providerModulePath -Force
if (-not [string]::Equals((Get-RunPodProviderApiBase), [string]$plan.api_base, [StringComparison]::Ordinal)) {
    throw 'Provider module API base does not match the approved plan.'
}
if (-not [string]::Equals(
    (Get-RunPodProviderGraphQLApiBase),
    [string]$plan.graphql_api_base,
    [StringComparison]::Ordinal
)) {
    throw 'Provider module GraphQL API base does not match the approved plan.'
}

[IO.Directory]::CreateDirectory($deploymentDirectory) | Out-Null
$lockStream = $null
$podId = $null
$createSubmitted = $false
$ownershipBound = $false
try {
    try {
        $lockStream = [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    }
    catch {
        throw 'Another RunPod deployment execution holds the exclusive deployment lock.'
    }

    $pod = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $existingState = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
        if (-not [string]::Equals([string]$existingState.plan_sha256, $planSha256, [StringComparison]::Ordinal)) {
            throw 'Existing deployment state belongs to a different plan. Refusing to create or adopt a pod.'
        }
        $existingPodId = if ($null -ne $existingState.PSObject.Properties['pod_id']) {
            [string]$existingState.pod_id
        }
        else {
            ''
        }
        if ([string]::IsNullOrWhiteSpace($existingPodId)) {
            $reconciledPods = @(Get-RunPodPodsByName -ApiKey $providerApiKey -Name ([string]$plan.target.pod_name))
            if ($reconciledPods.Count -ne 1) {
                throw "Existing deployment state is ambiguous; reconciliation found $($reconciledPods.Count) exact pods. No POST was retried."
            }
            $binding = Get-OwnedRunPodCandidate `
                -ApiKey $providerApiKey `
                -Candidate $reconciledPods[0] `
                -ExpectedName ([string]$plan.target.pod_name)
            $pod = $binding.Pod
            $podId = $binding.PodId
            $ownershipBound = $true
            [void](Assert-RunPodPodContract -Pod $pod -Target $plan.target)
        }
        else {
            $podId = $existingPodId
            $pod = Get-RunPodPod -ApiKey $providerApiKey -PodId $podId
            [void](Assert-RunPodPodOwnership `
                -Pod $pod `
                -ExpectedPodId $podId `
                -ExpectedName ([string]$plan.target.pod_name))
            $ownershipBound = $true
            [void](Assert-RunPodPodContract -Pod $pod -Target $plan.target)
        }
        if (
            $null -ne $existingState.PSObject.Properties['outcome'] -and
            [string]$existingState.outcome -eq 'ready'
        ) {
            $readyEndpoint = Get-RunPodSshEndpoint -Pod $pod
            if ($null -eq $readyEndpoint) {
                throw 'Ready deployment state no longer has a provider-reported SSH endpoint.'
            }
            $localSessionReady = $false
            try {
                $readySession = Get-RunPodSession
                $modelSourceBindingReady = Test-QwenReadyModelSourceBinding `
                    -ExistingState $existingState `
                    -ReadySession $readySession `
                    -ExpectedModelSource $effectiveModelSource `
                    -ExpectedModelSourcePolicy $modelSourcePolicy `
                    -ExpectedBackupManifestSha256 $effectiveBackupManifestSha256 `
                    -RequiredModel ([string]$plan.workload.model_id)
                $localSessionReady = (
                    [string]::Equals([string]$readySession.PodId, $podId, [StringComparison]::Ordinal) -and
                    [string]::Equals(
                        [string]$readySession.DeploymentPlanSha256,
                        $planSha256,
                        [StringComparison]::Ordinal
                    ) -and
                    [string]::Equals(
                        [string]$readySession.SshHost,
                        [string]$readyEndpoint.SshHost,
                        [StringComparison]::OrdinalIgnoreCase
                    ) -and
                    [int]$readySession.SshPort -eq [int]$readyEndpoint.SshPort -and
                    $modelSourceBindingReady
                )
            }
            catch {
                $localSessionReady = $false
            }
            if ($localSessionReady) {
                $alreadyReady = [ordered]@{
                    operation = 'runpod.provision'
                    mode = 'execute'
                    mutation_state = 'adopted'
                    mutation_performed = $false
                    outcome = 'ready'
                    plan_sha256 = $planSha256
                    pod_id = $podId
                    ssh_host = $readyEndpoint.SshHost
                    ssh_port = $readyEndpoint.SshPort
                    state_path = $statePath
                }
                Write-Result -Result $alreadyReady
                exit 0
            }
        }
    }
    else {
        $preexistingPods = @(Get-RunPodPodsByName -ApiKey $providerApiKey -Name ([string]$plan.target.pod_name))
        if ($preexistingPods.Count -gt 1) {
            throw "Multiple RunPod pods already use the unique deployment witness '$($plan.target.pod_name)'."
        }
        if ($preexistingPods.Count -eq 1) {
            $binding = Get-OwnedRunPodCandidate `
                -ApiKey $providerApiKey `
                -Candidate $preexistingPods[0] `
                -ExpectedName ([string]$plan.target.pod_name)
            $pod = $binding.Pod
            $podId = $binding.PodId
            $ownershipBound = $true
            [void](Assert-RunPodPodContract -Pod $pod -Target $plan.target)
        }
        else {
        # Global stock is relevant only when this execution is about to submit
        # a new Pod. An already-owned exact Pod is qualified from its
        # authoritative GET record, including its actual price, and must not be
        # left running merely because no additional global stock is available.
        $offer = Get-RunPodGpuOffer `
            -ApiKey $providerApiKey `
            -GpuTypeId ([string]$plan.target.gpu_type_id)
        Assert-RunPodGpuOffer `
            -Offer $offer `
            -ExpectedGpuTypeId ([string]$plan.target.gpu_type_id) `
            -MinimumMemoryGb 80 `
            -MaximumSecurePrice ([decimal]$plan.target.max_compute_usd_per_hour)

        $submittedState = [ordered]@{
            schema_version = 1
            deployment_id = [string]$plan.deployment_id
            deployment_profile_id = [string]$plan.deployment_profile_id
            plan_sha256 = $planSha256
            mutation_state = 'create_submitted'
            outcome = 'pending'
            pod_id = $null
            submitted_at_utc = [DateTime]::UtcNow.ToString('o')
        }
        Write-AtomicJson -Path $statePath -Value $submittedState
        $createSubmitted = $true
        try {
            # Exactly one create POST. New-RunPodPod contains no retry path.
            $pod = New-RunPodPod -ApiKey $providerApiKey -CreateRequest $plan.create_request
        }
        catch {
            $reconciledPods = @()
            try {
                $reconciledPods = @(Get-RunPodPodsByName -ApiKey $providerApiKey -Name ([string]$plan.target.pod_name))
            }
            catch {
                $reconciledPods = @()
            }
            if ($reconciledPods.Count -eq 1) {
                $binding = Get-OwnedRunPodCandidate `
                    -ApiKey $providerApiKey `
                    -Candidate $reconciledPods[0] `
                    -ExpectedName ([string]$plan.target.pod_name)
                $pod = $binding.Pod
                $podId = $binding.PodId
                $ownershipBound = $true
            }
            else {
            $unknownState = [ordered]@{
                schema_version = 1
                deployment_id = [string]$plan.deployment_id
                deployment_profile_id = [string]$plan.deployment_profile_id
                plan_sha256 = $planSha256
                mutation_state = 'unknown'
                outcome = 'attention_required'
                pod_id = $null
                submitted_at_utc = $submittedState.submitted_at_utc
                failed_at_utc = [DateTime]::UtcNow.ToString('o')
                reason = "create_response_ambiguous_no_retry_reconciliation_count_$($reconciledPods.Count)"
            }
            Write-AtomicJson -Path $statePath -Value $unknownState
            throw
            }
        }
        if ([string]::IsNullOrWhiteSpace($podId)) {
            $podId = Get-RunPodPodId -Pod $pod
        }
        if ([string]::IsNullOrWhiteSpace($podId)) {
            try {
                $reconciledPods = @(Get-RunPodPodsByName -ApiKey $providerApiKey -Name ([string]$plan.target.pod_name))
                if ($reconciledPods.Count -eq 1) {
                    $binding = Get-OwnedRunPodCandidate `
                        -ApiKey $providerApiKey `
                        -Candidate $reconciledPods[0] `
                        -ExpectedName ([string]$plan.target.pod_name)
                    $pod = $binding.Pod
                    $podId = $binding.PodId
                    $ownershipBound = $true
                }
            }
            catch {
                $podId = $null
                $ownershipBound = $false
            }
        }
        if ([string]::IsNullOrWhiteSpace($podId)) {
            $missingIdState = [ordered]@{
                schema_version = 1
                deployment_id = [string]$plan.deployment_id
                deployment_profile_id = [string]$plan.deployment_profile_id
                plan_sha256 = $planSha256
                mutation_state = 'unknown'
                outcome = 'attention_required'
                pod_id = $null
                submitted_at_utc = $submittedState.submitted_at_utc
                failed_at_utc = [DateTime]::UtcNow.ToString('o')
                reason = 'create_response_missing_pod_id_no_retry'
            }
            Write-AtomicJson -Path $statePath -Value $missingIdState
            throw 'RunPod create returned no pod id. The POST will not be retried.'
        }
        $createdState = [ordered]@{
            schema_version = 1
            deployment_id = [string]$plan.deployment_id
            deployment_profile_id = [string]$plan.deployment_profile_id
            plan_sha256 = $planSha256
            mutation_state = 'create_response_received'
            outcome = 'pending_binding'
            pod_id = $podId
            ownership_bound = $ownershipBound
            secure_compute_usd_per_hour = [decimal]$offer.secure_price
            submitted_at_utc = $submittedState.submitted_at_utc
            created_at_utc = [DateTime]::UtcNow.ToString('o')
        }
        Write-AtomicJson -Path $statePath -Value $createdState
        }
    }

    $pod = Get-RunPodPod -ApiKey $providerApiKey -PodId $podId
    if ($createSubmitted -and -not $ownershipBound) {
        [void](Assert-RunPodPodOwnership `
            -Pod $pod `
            -ExpectedPodId $podId `
            -ExpectedName ([string]$plan.target.pod_name))
        $ownershipBound = $true
    }
    [void](Assert-RunPodPodContract -Pod $pod -Target $plan.target)
    $effectiveComputeUsdPerHour = Get-AuthoritativeRunPodComputePrice -Pod $pod
    if (-not $createSubmitted) {
        $ownershipBound = $true
    }
    $provisioningState = [ordered]@{
        schema_version = 1
        deployment_id = [string]$plan.deployment_id
        deployment_profile_id = [string]$plan.deployment_profile_id
        plan_sha256 = $planSha256
        mutation_state = if ($createSubmitted) { 'created' } else { 'adopted' }
        outcome = 'provisioning'
        pod_id = $podId
        secure_compute_usd_per_hour = $effectiveComputeUsdPerHour
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    Write-AtomicJson -Path $statePath -Value $provisioningState
    $ssh = Wait-RunPodSsh `
        -ApiKey $providerApiKey `
        -PodId $podId `
        -TimeoutSeconds ([int]$plan.readiness.ssh_wait_timeout_seconds) `
        -PollIntervalSeconds ([int]$plan.readiness.ssh_poll_interval_seconds) `
        -ConnectTimeoutSeconds ([int]$plan.readiness.ssh_connect_timeout_seconds)

    $provisioningState['outcome'] = 'bootstrapping'
    $provisioningState['ssh_host'] = [string]$ssh.SshHost
    $provisioningState['ssh_port'] = [int]$ssh.SshPort
    $provisioningState['updated_at_utc'] = [DateTime]::UtcNow.ToString('o')
    Write-AtomicJson -Path $statePath -Value $provisioningState

    $deployScript = Join-Path $PSScriptRoot 'runpod-deploy.ps1'
    $deployParameters = @{
        SshHost = [string]$ssh.SshHost
        SshPort = [int]$ssh.SshPort
        SshUser = [string]$plan.readiness.ssh_user
        IdentityFile = $resolvedIdentity
        Model = [string]$plan.workload.model_id
        DownloadAll = [bool]$plan.workload.download_all
        ModelSource = if ($effectiveModelSource -eq 'local-only') { 'LocalOnly' } else { 'Hub' }
        LocalModelRoot = $resolvedLocalModelRoot
        LaunchGui = $false
        LocalPort = $LocalPort
        RemoteDir = [string]$plan.workload.remote_dir
        PodId = $podId
        DeploymentId = [string]$plan.deployment_id
        DeploymentProfileId = [string]$plan.deployment_profile_id
        DeploymentPlanSha256 = $planSha256
        ProvisioningStatePath = $statePath
        ExpectedGpuName = [string]$plan.target.expected_gpu_name
        ExpectedGpuMemoryMiB = [int]$plan.target.minimum_gpu_memory_mib
        ExpectedComputeCapability = [string]$plan.target.expected_compute_capability
        ExpectedCudaRelease = [string]$plan.target.expected_cuda_release
    }
    $previousProviderKey = $env:RUNPOD_API_KEY
    try {
        # The provider credential is not inherited by SSH, SCP or later local
        # GUI processes. Existing deployment code receives only the model key.
        Remove-Item Env:RUNPOD_API_KEY -ErrorAction SilentlyContinue
        & $deployScript @deployParameters
    }
    catch { throw }
    finally {
        $env:RUNPOD_API_KEY = $previousProviderKey
    }

    $readyState = [ordered]@{
        schema_version = 1
        deployment_id = [string]$plan.deployment_id
        deployment_profile_id = [string]$plan.deployment_profile_id
        plan_sha256 = $planSha256
        mutation_state = if ($createSubmitted) { 'created' } else { 'adopted' }
        outcome = 'ready'
        model_source = $effectiveModelSource
        model_source_policy = $modelSourcePolicy
        model_backup_manifest_sha256 = $effectiveBackupManifestSha256
        pod_id = $podId
        cloud_type = [string]$plan.target.cloud_type
        gpu_type_id = [string]$plan.target.gpu_type_id
        image_name = [string]$plan.target.image_name
        volume_gb = [int]$plan.target.volume_gb
        volume_mount_path = [string]$plan.target.volume_mount_path
        model_id = [string]$plan.workload.model_id
        context_tokens = [int]$plan.workload.context_tokens
        ssh_host = [string]$ssh.SshHost
        ssh_port = [int]$ssh.SshPort
        secure_compute_usd_per_hour = $effectiveComputeUsdPerHour
        ready_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    Write-AtomicJson -Path $statePath -Value $readyState
    $result = [ordered]@{
        operation = 'runpod.provision'
        mode = 'execute'
        mutation_state = $readyState.mutation_state
        mutation_performed = $createSubmitted
        outcome = 'ready'
        plan_sha256 = $planSha256
        pod_id = $podId
        ssh_host = [string]$ssh.SshHost
        ssh_port = [int]$ssh.SshPort
        effective_spec = [ordered]@{
            cloud_type = [string]$plan.target.cloud_type
            gpu_type_id = [string]$plan.target.gpu_type_id
            gpu_count = [int]$plan.target.gpu_count
            image_name = [string]$plan.target.image_name
            volume_gb = [int]$plan.target.volume_gb
            volume_mount_path = [string]$plan.target.volume_mount_path
            model_source = $effectiveModelSource
            model_source_policy = [string]$plan.execution_policy.model_source_policy
            compute_usd_per_hour = $effectiveComputeUsdPerHour
        }
        state_path = $statePath
        next_action = 'run scripts/runpod-gui.ps1 when interactive access is desired'
    }
    Write-Result -Result $result
}
catch {
    $originalError = $_
    $unboundResponsePodId = if ($ownershipBound) { $null } else { $podId }
    if ($createSubmitted -and -not $ownershipBound) {
        try {
            $rollbackCandidates = @(
                Get-RunPodPodsByName -ApiKey $providerApiKey -Name ([string]$plan.target.pod_name)
            )
            if ($rollbackCandidates.Count -eq 1) {
                $binding = Get-OwnedRunPodCandidate `
                    -ApiKey $providerApiKey `
                    -Candidate $rollbackCandidates[0] `
                    -ExpectedName ([string]$plan.target.pod_name)
                $podId = $binding.PodId
                $ownershipBound = $true
            }
        }
        catch {
            # Remain unbound; an unverified response id is never a stop target.
        }
    }
    if ($ownershipBound -and -not [string]::IsNullOrWhiteSpace([string]$podId)) {
        $stopped = $false
        $sessionInvalidated = $false
        try {
            [void](Stop-RunPodPod -ApiKey $providerApiKey -PodId $podId)
            $stopped = $true
        }
        catch {
            $stopped = $false
        }
        $sessionInvalidated = Disable-BoundRunPodSession -PodId $podId -PlanSha256 $planSha256
        $rollbackComplete = $stopped -and $sessionInvalidated
        $failedState = [ordered]@{
            schema_version = 1
            deployment_id = [string]$plan.deployment_id
            deployment_profile_id = [string]$plan.deployment_profile_id
            plan_sha256 = $planSha256
            mutation_state = if ($createSubmitted) { 'created' } else { 'adopted' }
            outcome = if ($rollbackComplete) { 'stopped_after_failure' } else { 'attention_required' }
            pod_id = $podId
            failed_at_utc = [DateTime]::UtcNow.ToString('o')
            reason = if ($rollbackComplete) {
                'exact_pod_stopped_and_local_session_invalidated_after_failure'
            }
            elseif (-not $stopped) {
                'exact_pod_stop_unconfirmed_attention_required'
            }
            else {
                'exact_pod_stopped_but_local_session_invalidation_failed'
            }
        }
        Write-AtomicJson -Path $statePath -Value $failedState
    }
    elseif ($createSubmitted) {
        $unboundState = [ordered]@{
            schema_version = 1
            deployment_id = [string]$plan.deployment_id
            deployment_profile_id = [string]$plan.deployment_profile_id
            plan_sha256 = $planSha256
            mutation_state = 'unknown'
            outcome = 'attention_required'
            pod_id = $null
            response_pod_id_unbound = $unboundResponsePodId
            failed_at_utc = [DateTime]::UtcNow.ToString('o')
            reason = 'create_submitted_but_exact_name_and_contract_ownership_not_bound_no_stop_attempted'
        }
        Write-AtomicJson -Path $statePath -Value $unboundState
    }
    throw $originalError
}
finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
}

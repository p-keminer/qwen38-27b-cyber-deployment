[CmdletBinding()]
param(
    [ValidateRange(10, 300)]
    [int]$RequestTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RunPod.Common.psm1') -Force

$script:AcceptanceGateId = 'a100-runtime-acceptance-v1'
$script:AcceptanceModelId = 'uncensored-q6'
$script:AcceptanceExpectedContent = 'A100_OK'
$script:AcceptanceSeed = 424242
$script:AcceptanceMaxTokens = 16
$script:AcceptanceMinimumProcessMemoryMiB = 30000
$script:AcceptanceDeploymentProfileId = 'a100-pcie-80gb-q6-v1'

function Get-A100RequiredProperty {
    param(
        [AllowNull()]
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name,

        [switch]$AllowNull
    )

    if ($null -eq $InputObject) {
        throw "Acceptance evidence is missing the '$Name' property."
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or ($null -eq $property.Value -and -not $AllowNull)) {
        throw "Acceptance evidence is missing the '$Name' property."
    }
    return $property.Value
}

function ConvertTo-A100Int64 {
    param(
        [AllowNull()]
        [Parameter(Mandatory)]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Name,

        [int64]$Minimum = 0,

        [int64]$Maximum = [int64]::MaxValue
    )

    $text = [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    [int64]$parsed = 0
    if (
        -not [int64]::TryParse(
            $text,
            [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed
        ) -or
        $parsed -lt $Minimum -or
        $parsed -gt $Maximum
    ) {
        throw "Acceptance evidence '$Name' is not an integer in the required range."
    }
    return $parsed
}

function ConvertTo-A100Double {
    param(
        [AllowNull()]
        [Parameter(Mandatory)]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $text = [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    [double]$parsed = 0
    if (
        -not [double]::TryParse(
            $text,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed
        ) -or
        [double]::IsNaN($parsed) -or
        [double]::IsInfinity($parsed) -or
        $parsed -lt 0
    ) {
        throw "Acceptance evidence '$Name' is not a finite non-negative number."
    }
    return $parsed
}

function Get-A100FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Acceptance contract file is missing: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-A100PythonCommand {
    foreach ($name in @('python.exe', 'python')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }
    throw 'Python 3.12 is required to validate the A100 deployment binding.'
}

function Assert-A100DeploymentBindingContract {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$DeploymentManifest,
        [Parameter(Mandatory)]$CanonicalPlan,
        [Parameter(Mandatory)][string]$DeploymentManifestSha256,
        [Parameter(Mandatory)][string]$CanonicalPlanSha256,
        [Parameter(Mandatory)][string]$RenderedPlanSha256,
        [Parameter(Mandatory)][string]$ModelManifestSha256
    )

    foreach ($hash in @(
        $DeploymentManifestSha256,
        $CanonicalPlanSha256,
        $RenderedPlanSha256,
        $ModelManifestSha256
    )) {
        if (-not [regex]::IsMatch($hash, '^[0-9a-f]{64}$')) {
            throw 'The deployment binding contains an invalid lowercase SHA-256 value.'
        }
    }

    $manifestDeploymentId = [string](Get-A100RequiredProperty `
        -InputObject $DeploymentManifest `
        -Name 'deployment_id')
    $manifestProfileId = [string](Get-A100RequiredProperty `
        -InputObject $DeploymentManifest `
        -Name 'deployment_profile_id')
    $manifestPodName = [string](Get-A100RequiredProperty `
        -InputObject $DeploymentManifest `
        -Name 'pod_name')
    $manifestWorkload = Get-A100RequiredProperty -InputObject $DeploymentManifest -Name 'workload'
    $planDeploymentId = [string](Get-A100RequiredProperty -InputObject $CanonicalPlan -Name 'deployment_id')
    $planProfileId = [string](Get-A100RequiredProperty `
        -InputObject $CanonicalPlan `
        -Name 'deployment_profile_id')
    $planTarget = Get-A100RequiredProperty -InputObject $CanonicalPlan -Name 'target'
    $planCreateRequest = Get-A100RequiredProperty -InputObject $CanonicalPlan -Name 'create_request'
    $planWorkload = Get-A100RequiredProperty -InputObject $CanonicalPlan -Name 'workload'

    $sessionDeploymentId = [string](Get-A100RequiredProperty -InputObject $Session -Name 'DeploymentId')
    $sessionProfileId = [string](Get-A100RequiredProperty `
        -InputObject $Session `
        -Name 'DeploymentProfileId')
    $sessionPlanSha256 = [string](Get-A100RequiredProperty `
        -InputObject $Session `
        -Name 'DeploymentPlanSha256')
    if (
        -not [string]::Equals($sessionDeploymentId, $manifestDeploymentId, [StringComparison]::Ordinal) -or
        -not [string]::Equals($sessionDeploymentId, $planDeploymentId, [StringComparison]::Ordinal) -or
        -not [string]::Equals($sessionDeploymentId, $manifestPodName, [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            $sessionDeploymentId,
            [string](Get-A100RequiredProperty -InputObject $planTarget -Name 'pod_name'),
            [StringComparison]::Ordinal
        ) -or
        -not [string]::Equals(
            $sessionDeploymentId,
            [string](Get-A100RequiredProperty -InputObject $planCreateRequest -Name 'name'),
            [StringComparison]::Ordinal
        )
    ) {
        throw 'The session, deployment manifest, and canonical plan have different deployment identities.'
    }
    if (
        -not [string]::Equals($sessionProfileId, $script:AcceptanceDeploymentProfileId, [StringComparison]::Ordinal) -or
        -not [string]::Equals($sessionProfileId, $manifestProfileId, [StringComparison]::Ordinal) -or
        -not [string]::Equals($sessionProfileId, $planProfileId, [StringComparison]::Ordinal)
    ) {
        throw 'The session, deployment manifest, and canonical plan have different deployment profiles.'
    }
    if (
        -not [string]::Equals($sessionPlanSha256, $CanonicalPlanSha256, [StringComparison]::Ordinal) -or
        -not [string]::Equals($CanonicalPlanSha256, $RenderedPlanSha256, [StringComparison]::Ordinal)
    ) {
        throw 'The qualified session is not bound to the canonical plan rendered from the validated manifest.'
    }

    $manifestModelSha256 = [string](Get-A100RequiredProperty `
        -InputObject $manifestWorkload `
        -Name 'model_manifest_sha256')
    $planModelSha256 = [string](Get-A100RequiredProperty `
        -InputObject $planWorkload `
        -Name 'model_manifest_sha256')
    if (
        -not [string]::Equals($manifestModelSha256, $ModelManifestSha256, [StringComparison]::Ordinal) -or
        -not [string]::Equals($planModelSha256, $ModelManifestSha256, [StringComparison]::Ordinal)
    ) {
        throw 'The deployment manifest and canonical plan are not bound to the current model manifest.'
    }
    if (
        -not [string]::Equals(
            [string](Get-A100RequiredProperty -InputObject $Session -Name 'RemoteDir'),
            [string](Get-A100RequiredProperty -InputObject $manifestWorkload -Name 'remote_dir'),
            [StringComparison]::Ordinal
        ) -or
        -not [string]::Equals(
            [string](Get-A100RequiredProperty -InputObject $Session -Name 'ActiveModel'),
            [string](Get-A100RequiredProperty -InputObject $manifestWorkload -Name 'model_id'),
            [StringComparison]::Ordinal
        ) -or
        -not [string]::Equals(
            [string](Get-A100RequiredProperty -InputObject $Session -Name 'ActiveAlias'),
            [string](Get-A100RequiredProperty -InputObject $manifestWorkload -Name 'model_alias'),
            [StringComparison]::Ordinal
        ) -or
        -not [string]::Equals(
            [string](Get-A100RequiredProperty -InputObject $Session -Name 'LlamaBuildInfo'),
            [string](Get-A100RequiredProperty -InputObject $manifestWorkload -Name 'expected_llama_build_info'),
            [StringComparison]::Ordinal
        )
    ) {
        throw 'The qualified session workload does not match the validated deployment manifest.'
    }

    return [pscustomobject][ordered]@{
        verified = $true
        deployment_id = $sessionDeploymentId
        deployment_profile_id = $sessionProfileId
        deployment_manifest_sha256 = $DeploymentManifestSha256
        canonical_plan_sha256 = $CanonicalPlanSha256
        rendered_plan_sha256 = $RenderedPlanSha256
        model_manifest_sha256 = $ModelManifestSha256
        manifest_validator_passed = $true
        canonical_plan_matches_validated_manifest = $true
        qualified_session_matches_canonical_plan = $true
    }
}

function Get-A100DeploymentBindingEvidence {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Session
    )

    $deploymentManifestPath = Join-Path $ProjectRoot 'config\runpod-a100-pcie-deployment.json'
    $canonicalPlanPath = Join-Path `
        $ProjectRoot `
        ".runpod\deployments\$script:AcceptanceDeploymentProfileId\plan.json"
    $modelManifestPath = Join-Path $ProjectRoot 'config\models.json'
    $validatorPath = Join-Path $ProjectRoot 'scripts\validate_runpod_deployment_manifest.py'
    foreach ($path in @($deploymentManifestPath, $canonicalPlanPath, $modelManifestPath, $validatorPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Acceptance deployment binding file is missing: $path"
        }
    }

    $temporaryPlanPath = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "qwen-a100-acceptance-$PID-$([Guid]::NewGuid().ToString('N')).json"
    try {
        $python = Get-A100PythonCommand
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $validatorOutput = @(
                & $python `
                    $validatorPath `
                    '--manifest' $deploymentManifestPath `
                    '--plan-output' $temporaryPlanPath `
                    '--quiet' 2>&1
            )
            $validatorExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($validatorExitCode -ne 0) {
            $validatorOutput = $null
            throw 'The A100 deployment manifest failed its pinned validator.'
        }
        if (-not (Test-Path -LiteralPath $temporaryPlanPath -PathType Leaf)) {
            throw 'The A100 deployment validator did not render a canonical plan.'
        }

        $deploymentManifest = Get-Content `
            -LiteralPath $deploymentManifestPath `
            -Raw `
            -Encoding utf8 | ConvertFrom-Json
        $canonicalPlan = Get-Content `
            -LiteralPath $canonicalPlanPath `
            -Raw `
            -Encoding utf8 | ConvertFrom-Json
        return Assert-A100DeploymentBindingContract `
            -Session $Session `
            -DeploymentManifest $deploymentManifest `
            -CanonicalPlan $canonicalPlan `
            -DeploymentManifestSha256 (Get-A100FileSha256 -Path $deploymentManifestPath) `
            -CanonicalPlanSha256 (Get-A100FileSha256 -Path $canonicalPlanPath) `
            -RenderedPlanSha256 (Get-A100FileSha256 -Path $temporaryPlanPath) `
            -ModelManifestSha256 (Get-A100FileSha256 -Path $modelManifestPath)
    }
    finally {
        Remove-Item -LiteralPath $temporaryPlanPath -Force -ErrorAction SilentlyContinue
    }
}

function Assert-A100DeploymentBindingEvidenceForReport {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Evidence
    )

    foreach ($flagName in @(
        'verified',
        'manifest_validator_passed',
        'canonical_plan_matches_validated_manifest',
        'qualified_session_matches_canonical_plan'
    )) {
        $flag = Get-A100RequiredProperty -InputObject $Evidence -Name $flagName
        if ($flag -isnot [bool] -or -not $flag) {
            throw "Deployment binding report evidence '$flagName' is not exactly true."
        }
    }

    $sessionDeploymentId = [string](Get-A100RequiredProperty -InputObject $Session -Name 'DeploymentId')
    $sessionProfileId = [string](Get-A100RequiredProperty `
        -InputObject $Session `
        -Name 'DeploymentProfileId')
    $sessionPlanSha256 = [string](Get-A100RequiredProperty `
        -InputObject $Session `
        -Name 'DeploymentPlanSha256')
    $evidenceDeploymentId = [string](Get-A100RequiredProperty `
        -InputObject $Evidence `
        -Name 'deployment_id')
    $evidenceProfileId = [string](Get-A100RequiredProperty `
        -InputObject $Evidence `
        -Name 'deployment_profile_id')
    if (
        -not [string]::Equals($evidenceDeploymentId, $sessionDeploymentId, [StringComparison]::Ordinal) -or
        -not [string]::Equals($evidenceProfileId, $sessionProfileId, [StringComparison]::Ordinal)
    ) {
        throw 'Deployment binding report evidence does not identify the qualified session.'
    }

    $hashes = [ordered]@{}
    foreach ($hashName in @(
        'deployment_manifest_sha256',
        'canonical_plan_sha256',
        'rendered_plan_sha256',
        'model_manifest_sha256'
    )) {
        $hash = [string](Get-A100RequiredProperty -InputObject $Evidence -Name $hashName)
        if (-not [regex]::IsMatch($hash, '^[0-9a-f]{64}$')) {
            throw "Deployment binding report evidence '$hashName' is not a lowercase SHA-256 value."
        }
        $hashes[$hashName] = $hash
    }
    if (
        -not [string]::Equals($hashes['canonical_plan_sha256'], $sessionPlanSha256, [StringComparison]::Ordinal) -or
        -not [string]::Equals(
            $hashes['canonical_plan_sha256'],
            $hashes['rendered_plan_sha256'],
            [StringComparison]::Ordinal
        )
    ) {
        throw 'Deployment binding report evidence is not bound to the qualified session plan hash.'
    }
    $projectRoot = Get-QwenProjectRoot
    $actualDeploymentManifestSha256 = Get-A100FileSha256 `
        -Path (Join-Path $projectRoot 'config\runpod-a100-pcie-deployment.json')
    $actualCanonicalPlanSha256 = Get-A100FileSha256 `
        -Path (Join-Path `
            $projectRoot `
            ".runpod\deployments\$script:AcceptanceDeploymentProfileId\plan.json")
    $actualModelManifestSha256 = Get-A100FileSha256 `
        -Path (Join-Path $projectRoot 'config\models.json')
    if (
        -not [string]::Equals(
            $hashes['deployment_manifest_sha256'],
            $actualDeploymentManifestSha256,
            [StringComparison]::Ordinal
        ) -or
        -not [string]::Equals(
            $hashes['canonical_plan_sha256'],
            $actualCanonicalPlanSha256,
            [StringComparison]::Ordinal
        ) -or
        -not [string]::Equals(
            $hashes['model_manifest_sha256'],
            $actualModelManifestSha256,
            [StringComparison]::Ordinal
        )
    ) {
        throw 'Deployment binding report hashes do not match the current repository contract files.'
    }
    return $Evidence
}

function Assert-A100RuntimeEndpointContract {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)]$ModelsResponse,
        [Parameter(Mandatory)]$PropsResponse
    )

    $expectedAlias = [string](Get-A100RequiredProperty -InputObject $Model -Name 'alias')
    $expectedQuantization = [string](Get-A100RequiredProperty -InputObject $Model -Name 'quantization')
    $expectedFilename = [string](Get-A100RequiredProperty -InputObject $Model -Name 'filename')
    $expectedContext = ConvertTo-A100Int64 `
        -Value (Get-A100RequiredProperty -InputObject $Model -Name 'context_size') `
        -Name 'model.context_size' `
        -Minimum 262144 `
        -Maximum 262144
    $llamaCpp = Get-A100RequiredProperty -InputObject $Manifest -Name 'llama_cpp'
    $expectedBuild = [string](Get-A100RequiredProperty -InputObject $llamaCpp -Name 'expected_build_info')
    $defaultContext = ConvertTo-A100Int64 `
        -Value (Get-A100RequiredProperty -InputObject $llamaCpp -Name 'default_context_size') `
        -Name 'llama_cpp.default_context_size' `
        -Minimum 262144 `
        -Maximum 262144

    $activeModel = [string](Get-A100RequiredProperty -InputObject $Session -Name 'ActiveModel')
    $activeAlias = [string](Get-A100RequiredProperty -InputObject $Session -Name 'ActiveAlias')
    $sessionBuild = [string](Get-A100RequiredProperty -InputObject $Session -Name 'LlamaBuildInfo')
    $remoteDirectory = [string](Get-A100RequiredProperty -InputObject $Session -Name 'RemoteDir')
    if (
        -not [string]::Equals($activeModel, $script:AcceptanceModelId, [StringComparison]::Ordinal) -or
        -not [string]::Equals($activeAlias, $expectedAlias, [StringComparison]::Ordinal) -or
        -not [string]::Equals($sessionBuild, $expectedBuild, [StringComparison]::Ordinal)
    ) {
        throw 'The qualified session is not bound to the pinned Q6 model and llama.cpp build.'
    }

    $modelsData = @(Get-A100RequiredProperty -InputObject $ModelsResponse -Name 'data')
    if ($modelsData.Count -ne 1) {
        throw 'The model endpoint must expose exactly one model.'
    }
    $reportedModelId = [string](Get-A100RequiredProperty -InputObject $modelsData[0] -Name 'id')
    if (-not [string]::Equals($reportedModelId, $expectedAlias, [StringComparison]::Ordinal)) {
        throw 'The model endpoint is not Q6-only.'
    }

    $reportedAlias = [string](Get-A100RequiredProperty -InputObject $PropsResponse -Name 'model_alias')
    $reportedQuantization = [string](Get-A100RequiredProperty -InputObject $PropsResponse -Name 'model_ftype')
    $reportedPath = [string](Get-A100RequiredProperty -InputObject $PropsResponse -Name 'model_path')
    $reportedBuild = [string](Get-A100RequiredProperty -InputObject $PropsResponse -Name 'build_info')
    $generationSettings = Get-A100RequiredProperty `
        -InputObject $PropsResponse `
        -Name 'default_generation_settings'
    $reportedContext = ConvertTo-A100Int64 `
        -Value (Get-A100RequiredProperty -InputObject $generationSettings -Name 'n_ctx') `
        -Name 'props.default_generation_settings.n_ctx' `
        -Minimum 262144 `
        -Maximum 262144
    $expectedPath = $remoteDirectory.TrimEnd('/') + '/models/' + $script:AcceptanceModelId + '/' + $expectedFilename
    if (
        -not [string]::Equals($reportedAlias, $expectedAlias, [StringComparison]::Ordinal) -or
        -not [string]::Equals($reportedQuantization, $expectedQuantization, [StringComparison]::Ordinal) -or
        -not [string]::Equals($reportedPath, $expectedPath, [StringComparison]::Ordinal) -or
        -not [string]::Equals($reportedBuild, $expectedBuild, [StringComparison]::Ordinal) -or
        $reportedContext -ne $defaultContext -or
        $reportedContext -ne $expectedContext
    ) {
        throw 'The endpoint does not match the pinned Q6 path, quantization, build, and 262144-token context contract.'
    }

    return [pscustomobject][ordered]@{
        q6_only = $true
        exposed_model_count = 1
        model_id = $script:AcceptanceModelId
        model_alias = $reportedAlias
        quantization = $reportedQuantization
        model_filename = $expectedFilename
        model_path = $reportedPath
        llama_build_info = $reportedBuild
        context_tokens = $reportedContext
    }
}

function ConvertFrom-A100GpuEvidence {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][object[]]$RuntimeGateOutput,
        [Parameter(Mandatory)][object[]]$GpuTelemetryOutput
    )

    if ($RuntimeGateOutput.Count -ne 1) {
        throw 'The remote full-offload gate returned an unexpected result count.'
    }
    try {
        $runtimeGate = [string]$RuntimeGateOutput[0] | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'The remote full-offload gate did not return one valid JSON object.'
    }
    $runtimeSchemaVersion = ConvertTo-A100Int64 `
        -Value (Get-A100RequiredProperty -InputObject $runtimeGate -Name 'schema_version') `
        -Name 'runtime_gate.schema_version' `
        -Minimum 1 `
        -Maximum 1
    $processMemoryMiB = ConvertTo-A100Int64 `
        -Value (Get-A100RequiredProperty -InputObject $runtimeGate -Name 'process_memory_mib') `
        -Name 'runtime_gate.process_memory_mib' `
        -Minimum $script:AcceptanceMinimumProcessMemoryMiB
    $processChecks = [ordered]@{}
    $runtimeProcessMapping = [ordered]@{
        server_binary_exact = 'pinned_server_binary'
        host_loopback_exact = 'host_loopback'
        api_key_file_exact = 'key_file_enabled'
        no_ui_exact = 'web_ui_disabled'
        context_size_exact = 'context_262144_exact'
        api_only_build_profile_exact = 'api_only_build_profile'
        full_gpu_offload = 'full_gpu_offload'
    }
    foreach ($sourceName in $runtimeProcessMapping.Keys) {
        $value = Get-A100RequiredProperty -InputObject $runtimeGate -Name $sourceName
        if ($value -isnot [bool] -or -not $value) {
            throw "The remote llama-server process check '$sourceName' did not pass exactly."
        }
        $processChecks[$runtimeProcessMapping[$sourceName]] = $true
    }

    if ($GpuTelemetryOutput.Count -ne 1) {
        throw 'A100 telemetry must contain exactly one GPU row.'
    }
    $columns = @(([string]$GpuTelemetryOutput[0]).Split(',') | ForEach-Object { $_.Trim() })
    if ($columns.Count -ne 4) {
        throw 'A100 telemetry has an unexpected column count.'
    }
    $expectedName = [string](Get-A100RequiredProperty -InputObject $Session -Name 'GpuName')
    if (-not [string]::Equals($columns[0], $expectedName, [StringComparison]::Ordinal)) {
        throw 'A100 telemetry reports a different GPU identity.'
    }
    $minimumTotalMiB = ConvertTo-A100Int64 `
        -Value (Get-A100RequiredProperty -InputObject $Session -Name 'GpuMemoryMiB') `
        -Name 'session.GpuMemoryMiB' `
        -Minimum 80000
    $totalMiB = ConvertTo-A100Int64 -Value $columns[1] -Name 'gpu.memory_total_mib' -Minimum $minimumTotalMiB
    $usedMiB = ConvertTo-A100Int64 -Value $columns[2] -Name 'gpu.memory_used_mib'
    $freeMiB = ConvertTo-A100Int64 -Value $columns[3] -Name 'gpu.memory_free_mib'
    if ($processMemoryMiB -gt $usedMiB -or $usedMiB -gt $totalMiB -or $freeMiB -gt $totalMiB) {
        throw 'A100 process and device memory telemetry are inconsistent.'
    }

    return [pscustomobject][ordered]@{
        server_process = [pscustomobject][ordered]@{
            runtime_gate_schema_version = $runtimeSchemaVersion
            pinned_server_binary = $processChecks['pinned_server_binary']
            host_loopback = $processChecks['host_loopback']
            key_file_enabled = $processChecks['key_file_enabled']
            web_ui_disabled = $processChecks['web_ui_disabled']
            context_262144_exact = $processChecks['context_262144_exact']
            api_only_build_profile = $processChecks['api_only_build_profile']
            full_gpu_offload = $processChecks['full_gpu_offload']
            argv_verified_from_proc = $true
        }
        gpu_name = $columns[0]
        gpu_count = 1
        full_gpu_offload = $true
        runtime_gate_verified = $true
        process_memory_used_mib = $processMemoryMiB
        device_memory_total_mib = $totalMiB
        device_memory_used_mib = $usedMiB
        device_memory_free_mib = $freeMiB
    }
}

function ConvertTo-A100ChatAttempt {
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][int64]$WallTimeMilliseconds,
        [Parameter(Mandatory)][int]$AttemptNumber
    )

    if ($WallTimeMilliseconds -lt 0) {
        throw 'The local chat wall time is invalid.'
    }
    $choices = @(Get-A100RequiredProperty -InputObject $Response -Name 'choices')
    if ($choices.Count -ne 1) {
        throw 'The deterministic chat probe returned an unexpected choice count.'
    }
    $message = Get-A100RequiredProperty -InputObject $choices[0] -Name 'message'
    $content = [string](Get-A100RequiredProperty -InputObject $message -Name 'content')
    $normalizedContent = $content.Trim()
    if (-not [string]::Equals($normalizedContent, $script:AcceptanceExpectedContent, [StringComparison]::Ordinal)) {
        throw 'The deterministic chat probe did not return the exact acceptance marker.'
    }
    $finishReason = [string](Get-A100RequiredProperty -InputObject $choices[0] -Name 'finish_reason')
    if ([string]::IsNullOrWhiteSpace($finishReason)) {
        throw 'The deterministic chat probe lacks a finish reason.'
    }

    $usage = Get-A100RequiredProperty -InputObject $Response -Name 'usage'
    $promptTokens = ConvertTo-A100Int64 `
        -Value (Get-A100RequiredProperty -InputObject $usage -Name 'prompt_tokens') `
        -Name 'usage.prompt_tokens' `
        -Minimum 1
    $completionTokens = ConvertTo-A100Int64 `
        -Value (Get-A100RequiredProperty -InputObject $usage -Name 'completion_tokens') `
        -Name 'usage.completion_tokens' `
        -Minimum 1 `
        -Maximum $script:AcceptanceMaxTokens
    $totalTokens = ConvertTo-A100Int64 `
        -Value (Get-A100RequiredProperty -InputObject $usage -Name 'total_tokens') `
        -Name 'usage.total_tokens' `
        -Minimum 2
    if ($totalTokens -ne ($promptTokens + $completionTokens)) {
        throw 'The deterministic chat probe returned inconsistent token usage.'
    }

    $serverTimings = [ordered]@{ reported = $false }
    $timingsProperty = $Response.PSObject.Properties['timings']
    if ($null -ne $timingsProperty -and $null -ne $timingsProperty.Value) {
        $timings = $timingsProperty.Value
        $serverTimings = [ordered]@{
            reported = $true
            prompt_tokens = ConvertTo-A100Int64 `
                -Value (Get-A100RequiredProperty -InputObject $timings -Name 'prompt_n') `
                -Name 'timings.prompt_n'
            prompt_milliseconds = ConvertTo-A100Double `
                -Value (Get-A100RequiredProperty -InputObject $timings -Name 'prompt_ms') `
                -Name 'timings.prompt_ms'
            generated_tokens = ConvertTo-A100Int64 `
                -Value (Get-A100RequiredProperty -InputObject $timings -Name 'predicted_n') `
                -Name 'timings.predicted_n'
            generation_milliseconds = ConvertTo-A100Double `
                -Value (Get-A100RequiredProperty -InputObject $timings -Name 'predicted_ms') `
                -Name 'timings.predicted_ms'
        }
        foreach ($optionalName in @('prompt_per_second', 'predicted_per_second')) {
            $optionalProperty = $timings.PSObject.Properties[$optionalName]
            if ($null -ne $optionalProperty -and $null -ne $optionalProperty.Value) {
                $reportName = if ($optionalName -eq 'prompt_per_second') {
                    'prompt_tokens_per_second'
                }
                else {
                    'generation_tokens_per_second'
                }
                $serverTimings[$reportName] = ConvertTo-A100Double `
                    -Value $optionalProperty.Value `
                    -Name "timings.$optionalName"
            }
        }
    }

    return [pscustomobject][ordered]@{
        attempt = $AttemptNumber
        content = $script:AcceptanceExpectedContent
        finish_reason = $finishReason
        usage = [ordered]@{
            prompt_tokens = $promptTokens
            completion_tokens = $completionTokens
            total_tokens = $totalTokens
        }
        timing = [ordered]@{
            wall_milliseconds = $WallTimeMilliseconds
            server = $serverTimings
        }
    }
}

function Assert-A100ChatDeterminism {
    param([Parameter(Mandatory)][object[]]$Attempts)

    if ($Attempts.Count -ne 2) {
        throw 'The deterministic chat gate requires exactly two attempts.'
    }
    foreach ($attempt in $Attempts) {
        if (
            -not [string]::Equals(
                [string](Get-A100RequiredProperty -InputObject $attempt -Name 'content'),
                $script:AcceptanceExpectedContent,
                [StringComparison]::Ordinal
            )
        ) {
            throw 'The deterministic chat attempts do not match the acceptance marker.'
        }
    }
    return [pscustomobject][ordered]@{
        verified = $true
        attempts = 2
        expected_content = $script:AcceptanceExpectedContent
    }
}

function Invoke-A100LocalJsonRequest {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][ValidateSet('models', 'props', 'chat')][string]$RequestName,
        [ValidateSet('Get', 'Post')][string]$Method = 'Get',
        [AllowNull()][string]$Body,
        [ValidateRange(10, 300)][int]$TimeoutSeconds = 120
    )

    if (
        $Uri.Scheme -ne 'http' -or
        $Uri.Host -ne '127.0.0.1' -or
        -not [string]::IsNullOrEmpty($Uri.UserInfo)
    ) {
        throw 'The acceptance gate refuses a non-loopback model endpoint.'
    }
    try {
        $parameters = @{
            Uri = $Uri
            Headers = $Headers
            Method = $Method
            TimeoutSec = $TimeoutSeconds
            ErrorAction = 'Stop'
        }
        if ($Method -eq 'Post') {
            $parameters.ContentType = 'application/json'
            $parameters.Body = $Body
        }
        return Invoke-RestMethod @parameters
    }
    catch {
        throw [InvalidOperationException]::new("The local llama.cpp '$RequestName' acceptance request failed.")
    }
}

function Assert-A100UnauthenticatedStatusCode {
    param([Parameter(Mandatory)][int]$StatusCode)

    if ($StatusCode -ne 401 -and $StatusCode -ne 403) {
        throw "The unauthenticated llama.cpp request returned HTTP $StatusCode instead of 401 or 403."
    }
    return [pscustomobject][ordered]@{
        verified = $true
        unauthenticated_models_request_rejected = $true
        status_code = $StatusCode
        accepted_status_codes = @(401, 403)
    }
}

function Invoke-A100UnauthenticatedAuthProbe {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [ValidateRange(10, 300)][int]$TimeoutSeconds = 120
    )

    if (
        $Uri.Scheme -ne 'http' -or
        $Uri.Host -ne '127.0.0.1' -or
        -not [string]::IsNullOrEmpty($Uri.UserInfo)
    ) {
        throw 'The unauthenticated acceptance probe refuses a non-loopback endpoint.'
    }

    [int]$statusCode = 0
    try {
        $response = Invoke-WebRequest `
            -Uri $Uri `
            -Method Get `
            -UseBasicParsing `
            -TimeoutSec $TimeoutSeconds `
            -ErrorAction Stop
        $statusCode = [int]$response.StatusCode
    }
    catch {
        $exceptionResponse = $_.Exception.Response
        if ($null -eq $exceptionResponse) {
            throw [InvalidOperationException]::new(
                'The unauthenticated local llama.cpp authentication probe failed without an HTTP response.'
            )
        }
        $statusProperty = $exceptionResponse.PSObject.Properties['StatusCode']
        if ($null -eq $statusProperty -or $null -eq $statusProperty.Value) {
            throw [InvalidOperationException]::new(
                'The unauthenticated local llama.cpp authentication probe returned no HTTP status code.'
            )
        }
        $statusCode = [int]$statusProperty.Value
    }
    return Assert-A100UnauthenticatedStatusCode -StatusCode $statusCode
}

function New-A100AcceptanceReport {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)]$DeploymentBindingEvidence,
        [Parameter(Mandatory)]$AuthenticationEvidence,
        [Parameter(Mandatory)]$EndpointEvidence,
        [Parameter(Mandatory)]$GpuEvidence,
        [Parameter(Mandatory)][object[]]$ChatAttempts,
        [Parameter(Mandatory)]$DeterminismEvidence,
        [Parameter(Mandatory)][int64]$TotalWallMilliseconds
    )

    $promptTokens = [int64](($ChatAttempts | ForEach-Object { $_.usage.prompt_tokens } | Measure-Object -Sum).Sum)
    $completionTokens = [int64](($ChatAttempts | ForEach-Object { $_.usage.completion_tokens } | Measure-Object -Sum).Sum)
    $totalTokens = [int64](($ChatAttempts | ForEach-Object { $_.usage.total_tokens } | Measure-Object -Sum).Sum)
    $chatWallMilliseconds = [int64](($ChatAttempts | ForEach-Object { $_.timing.wall_milliseconds } | Measure-Object -Sum).Sum)
    $llamaCpp = Get-A100RequiredProperty -InputObject $Manifest -Name 'llama_cpp'
    $visionProjector = Get-A100RequiredProperty -InputObject $Model -Name 'vision_projector'
    $validatedDeploymentBindingEvidence = Assert-A100DeploymentBindingEvidenceForReport `
        -Session $Session `
        -Evidence $DeploymentBindingEvidence
    foreach ($flagName in @('verified', 'unauthenticated_models_request_rejected')) {
        $flag = Get-A100RequiredProperty -InputObject $AuthenticationEvidence -Name $flagName
        if ($flag -isnot [bool] -or -not $flag) {
            throw "Endpoint authentication report evidence '$flagName' is not exactly true."
        }
    }
    $authenticationStatusCode = ConvertTo-A100Int64 `
        -Value (Get-A100RequiredProperty -InputObject $AuthenticationEvidence -Name 'status_code') `
        -Name 'endpoint_authentication.status_code' `
        -Minimum 100 `
        -Maximum 599
    $validatedAuthenticationEvidence = Assert-A100UnauthenticatedStatusCode `
        -StatusCode ([int]$authenticationStatusCode)
    $validatedServerProcess = Get-A100RequiredProperty `
        -InputObject $GpuEvidence `
        -Name 'server_process'
    foreach ($flagName in @(
        'pinned_server_binary',
        'host_loopback',
        'key_file_enabled',
        'web_ui_disabled',
        'context_262144_exact',
        'api_only_build_profile',
        'full_gpu_offload',
        'argv_verified_from_proc'
    )) {
        $flag = Get-A100RequiredProperty -InputObject $validatedServerProcess -Name $flagName
        if ($flag -isnot [bool] -or -not $flag) {
            throw "Server process report evidence '$flagName' is not exactly true."
        }
    }

    return [pscustomobject][ordered]@{
        schema_version = 1
        gate_id = $script:AcceptanceGateId
        status = 'passed'
        generated_at_utc = [DateTime]::UtcNow.ToString('o')
        scope = [ordered]@{
            source = 'qualified_live_session'
            deployment_id = [string](Get-A100RequiredProperty -InputObject $Session -Name 'DeploymentId')
            deployment_profile_id = [string](Get-A100RequiredProperty -InputObject $Session -Name 'DeploymentProfileId')
            deployment_plan_sha256 = [string](Get-A100RequiredProperty -InputObject $Session -Name 'DeploymentPlanSha256')
            local_transport = 'ssh_tunnel_loopback'
        }
        runtime_contract = [ordered]@{
            hardware = [ordered]@{
                gpu_name = [string](Get-A100RequiredProperty -InputObject $Session -Name 'GpuName')
                gpu_count = ConvertTo-A100Int64 `
                    -Value (Get-A100RequiredProperty -InputObject $Session -Name 'GpuCount') `
                    -Name 'session.GpuCount' `
                    -Minimum 1 `
                    -Maximum 1
                compute_capability = [string](Get-A100RequiredProperty -InputObject $Session -Name 'ComputeCapability')
                cuda_release = [string](Get-A100RequiredProperty -InputObject $Session -Name 'CudaRelease')
            }
            model = [ordered]@{
                id = $script:AcceptanceModelId
                alias = [string](Get-A100RequiredProperty -InputObject $Model -Name 'alias')
                quantization = [string](Get-A100RequiredProperty -InputObject $Model -Name 'quantization')
                revision = [string](Get-A100RequiredProperty -InputObject $Model -Name 'revision')
                filename = [string](Get-A100RequiredProperty -InputObject $Model -Name 'filename')
                expected_sha256 = [string](Get-A100RequiredProperty -InputObject $Model -Name 'sha256')
                projector_filename = [string](Get-A100RequiredProperty -InputObject $visionProjector -Name 'filename')
                projector_expected_sha256 = [string](Get-A100RequiredProperty -InputObject $visionProjector -Name 'sha256')
                context_tokens = 262144
            }
            llama_cpp = [ordered]@{
                revision = [string](Get-A100RequiredProperty -InputObject $llamaCpp -Name 'revision')
                build_info = [string](Get-A100RequiredProperty -InputObject $llamaCpp -Name 'expected_build_info')
            }
        }
        checks = [ordered]@{
            qualified_session = [ordered]@{
                verified = $true
                deployment_binding = $validatedDeploymentBindingEvidence
            }
            server_process = $validatedServerProcess
            endpoint_authentication = $validatedAuthenticationEvidence
            endpoint_identity = $EndpointEvidence
            gpu = $GpuEvidence
            deterministic_chat = $DeterminismEvidence
        }
        timing = [ordered]@{
            total_gate_wall_milliseconds = $TotalWallMilliseconds
        }
        chat_probe = [ordered]@{
            request = [ordered]@{
                prompt_contract = 'fixed-marker-v1'
                thinking_enabled = $false
                temperature = 0
                top_p = 1
                seed = $script:AcceptanceSeed
                max_tokens = $script:AcceptanceMaxTokens
                stream = $false
            }
            attempts = @($ChatAttempts)
            aggregate = [ordered]@{
                wall_milliseconds = $chatWallMilliseconds
                usage = [ordered]@{
                    prompt_tokens = $promptTokens
                    completion_tokens = $completionTokens
                    total_tokens = $totalTokens
                }
                performance_threshold_applied = $false
            }
        }
    }
}

function Write-A100AcceptanceReport {
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$Directory,
        [AllowEmptyCollection()][string[]]$KnownSecrets = @()
    )

    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $leaf = "a100-runtime-$stamp-$([Guid]::NewGuid().ToString('N').Substring(0, 8)).json"
    $path = Join-Path $Directory $leaf
    $temporaryPath = "$path.tmp.$PID"
    $json = ($Report | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    foreach ($secret in @($KnownSecrets)) {
        if (
            -not [string]::IsNullOrEmpty($secret) -and
            $json.IndexOf($secret, [StringComparison]::Ordinal) -ge 0
        ) {
            throw 'Refusing to persist an acceptance report containing a known secret.'
        }
    }
    if (
        $json -match '(?i)"(?:authorization|api[_-]?key|identity_file|ssh_host|ssh_user)"\s*:' -or
        $json -match '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+'
    ) {
        throw 'Refusing to persist secret-bearing acceptance report fields.'
    }

    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            $json,
            (New-Object System.Text.UTF8Encoding($false))
        )
        [IO.File]::Move($temporaryPath, $path)
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
    return $path
}

function Invoke-A100RuntimeAcceptance {
    param([ValidateRange(10, 300)][int]$TimeoutSeconds = 120)

    $projectRoot = Get-QwenProjectRoot
    $reportDirectory = Join-Path $projectRoot 'artifacts\acceptance'
    $started = [Diagnostics.Stopwatch]::StartNew()
    $stage = 'qualified_session'
    $apiKey = $null
    $headers = $null
    $chatRequestJson = $null
    $reportPath = $null
    $session = $null
    $tunnelCreatedByAcceptance = $false
    try {
        $session = Get-RunPodSession
        Assert-RunPodQualifiedSession -Session $session
        $stage = 'deployment_binding'
        $deploymentBindingEvidence = Get-A100DeploymentBindingEvidence `
            -ProjectRoot $projectRoot `
            -Session $session
        $manifestPath = Join-Path $projectRoot 'config\models.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        $model = Get-RunPodModel -Model $script:AcceptanceModelId

        $stage = 'local_tunnel'
        $originalTunnelPid = $null
        $originalTunnelPidProperty = $session.PSObject.Properties['TunnelPid']
        if ($null -ne $originalTunnelPidProperty -and $null -ne $originalTunnelPidProperty.Value) {
            $originalTunnelPid = ConvertTo-A100Int64 `
                -Value $originalTunnelPidProperty.Value `
                -Name 'session.TunnelPid' `
                -Minimum 1
        }
        $session = Start-RunPodTunnel -Session $session
        $activeTunnelPid = ConvertTo-A100Int64 `
            -Value (Get-A100RequiredProperty -InputObject $session -Name 'TunnelPid') `
            -Name 'session.TunnelPid' `
            -Minimum 1
        $tunnelCreatedByAcceptance = (
            $null -eq $originalTunnelPid -or
            $activeTunnelPid -ne $originalTunnelPid
        )
        if ($tunnelCreatedByAcceptance) {
            # Save-RunPodSession uses an atomic replace. A hard interruption can
            # therefore never leave an untracked tunnel PID in the qualified session.
            Save-RunPodSession -Session $session
        }
        Wait-RunPodLocalEndpoint -Session $session -TimeoutSeconds $TimeoutSeconds
        $localPort = ConvertTo-A100Int64 `
            -Value (Get-A100RequiredProperty -InputObject $session -Name 'LocalPort') `
            -Name 'session.LocalPort' `
            -Minimum 1 `
            -Maximum 65535
        $origin = "http://127.0.0.1:$localPort"

        $stage = 'gpu_offload'
        $runtimeOutput = @(
            Invoke-RunPodSshBounded `
                -Session $session `
                -RemoteCommand "bash '$($session.RemoteDir)/runpod/runtime-gate.sh' $script:AcceptanceMinimumProcessMemoryMiB" `
                -TimeoutSeconds 40
        )
        $gpuOutput = @(
            Invoke-RunPodSshBounded `
                -Session $session `
                -RemoteCommand 'nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free --format=csv,noheader,nounits' `
                -TimeoutSeconds 40
        )
        $gpuEvidence = ConvertFrom-A100GpuEvidence `
            -Session $session `
            -RuntimeGateOutput $runtimeOutput `
            -GpuTelemetryOutput $gpuOutput

        $stage = 'endpoint_authentication'
        $authenticationEvidence = Invoke-A100UnauthenticatedAuthProbe `
            -Uri "$origin/v1/models" `
            -TimeoutSeconds $TimeoutSeconds

        $stage = 'endpoint_identity'
        $apiKey = Get-RunPodApiKey
        $headers = @{ Authorization = "Bearer $apiKey" }
        $models = Invoke-A100LocalJsonRequest `
            -Uri "$origin/v1/models" `
            -Headers $headers `
            -RequestName models `
            -TimeoutSeconds $TimeoutSeconds
        $props = Invoke-A100LocalJsonRequest `
            -Uri "$origin/props" `
            -Headers $headers `
            -RequestName props `
            -TimeoutSeconds $TimeoutSeconds
        $endpointEvidence = Assert-A100RuntimeEndpointContract `
            -Session $session `
            -Manifest $manifest `
            -Model $model `
            -ModelsResponse $models `
            -PropsResponse $props

        $stage = 'deterministic_chat'
        $chatRequest = [ordered]@{
            model = [string]$model.alias
            messages = @(
                [ordered]@{
                    role = 'system'
                    content = 'Return exactly A100_OK. Do not add punctuation, formatting, or explanation.'
                },
                [ordered]@{
                    role = 'user'
                    content = 'Return the required acceptance marker. /no_think'
                }
            )
            chat_template_kwargs = [ordered]@{
                enable_thinking = $false
            }
            temperature = 0
            top_p = 1
            seed = $script:AcceptanceSeed
            max_tokens = $script:AcceptanceMaxTokens
            stream = $false
        }
        $chatRequestJson = $chatRequest | ConvertTo-Json -Depth 6 -Compress
        $attempts = @()
        foreach ($attemptNumber in 1..2) {
            $requestTimer = [Diagnostics.Stopwatch]::StartNew()
            $response = Invoke-A100LocalJsonRequest `
                -Uri "$origin/v1/chat/completions" `
                -Headers $headers `
                -RequestName chat `
                -Method Post `
                -Body $chatRequestJson `
                -TimeoutSeconds $TimeoutSeconds
            $requestTimer.Stop()
            $attempts += ConvertTo-A100ChatAttempt `
                -Response $response `
                -WallTimeMilliseconds $requestTimer.ElapsedMilliseconds `
                -AttemptNumber $attemptNumber
        }
        $determinism = Assert-A100ChatDeterminism -Attempts $attempts

        if ($tunnelCreatedByAcceptance) {
            $stage = 'local_tunnel_cleanup'
            Stop-RunPodTunnel -Session $session
            $tunnelCreatedByAcceptance = $false
        }

        $started.Stop()
        $stage = 'report'
        $report = New-A100AcceptanceReport `
            -Session $session `
            -Manifest $manifest `
            -Model $model `
            -DeploymentBindingEvidence $deploymentBindingEvidence `
            -AuthenticationEvidence $authenticationEvidence `
            -EndpointEvidence $endpointEvidence `
            -GpuEvidence $gpuEvidence `
            -ChatAttempts $attempts `
            -DeterminismEvidence $determinism `
            -TotalWallMilliseconds $started.ElapsedMilliseconds
        $reportPath = Write-A100AcceptanceReport `
            -Report $report `
            -Directory $reportDirectory `
            -KnownSecrets @($apiKey)
        Write-Host "A100 runtime acceptance passed. Report: $reportPath"
        return [pscustomobject]@{
            Status = 'passed'
            ReportPath = $reportPath
        }
    }
    catch {
        $failure = $_
        $started.Stop()
        if ($stage -ne 'report') {
            $failureReport = [pscustomobject][ordered]@{
                schema_version = 1
                gate_id = $script:AcceptanceGateId
                status = 'failed'
                generated_at_utc = [DateTime]::UtcNow.ToString('o')
                failed_stage = $stage
                total_wall_milliseconds = $started.ElapsedMilliseconds
                diagnostic = 'Inspect the qualified session, local tunnel, remote runtime gate, and llama.cpp logs.'
            }
            try {
                $reportPath = Write-A100AcceptanceReport `
                    -Report $failureReport `
                    -Directory $reportDirectory `
                    -KnownSecrets @($apiKey)
            }
            catch {
                $reportPath = $null
            }
        }
        $reportSuffix = if ($null -ne $reportPath) { " Report: $reportPath" } else { '' }
        throw [InvalidOperationException]::new(
            "A100 runtime acceptance failed at stage '$stage'.$reportSuffix",
            $failure.Exception
        )
    }
    finally {
        if ($tunnelCreatedByAcceptance -and $null -ne $session) {
            Stop-RunPodTunnel -Session $session
            $tunnelCreatedByAcceptance = $false
        }
        if ($null -ne $headers) {
            $headers.Clear()
        }
        $apiKey = $null
        $chatRequestJson = $null
    }
}

# Dot-sourcing exposes only the pure contract/report functions to offline tests.
# Direct invocation performs the qualified live acceptance gate.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-A100RuntimeAcceptance -TimeoutSeconds $RequestTimeoutSeconds | Out-Null
}

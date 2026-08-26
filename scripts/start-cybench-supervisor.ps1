param(
    [ValidatePattern('^[A-Za-z0-9]+$')][string]$CoreTaskId,
    [string]$CoreLogDirectory,
    [ValidateRange(10, 300)][int]$PollSeconds = 30,
    [ValidateRange(60, 3600)][int]$FinalHealthTimeoutSeconds = 900,
    [ValidateSet('phase-limit-owned-v1')]
    [string]$ExpectedModelApiTimeoutPolicy = 'phase-limit-owned-v1',
    [ValidateRange(7201, 86400)]
    [int]$ExpectedModelApiClientTimeoutSeconds = 7500,
    [ValidateRange(4096, 262144)][int]$CoreExpectedCompactionThresholdTokens = 160000,
    [ValidateRange(4096, 262144)][int]$CeilingExpectedCompactionThresholdTokens = 160000,
    [ValidateSet('legacy-unversioned', 'neutral-v1', 'baseline-v1', 'efficient-v2')]
    [string]$CoreExpectedAgentPolicy = 'neutral-v1',
    [ValidateSet('legacy-unversioned', 'neutral-v1', 'baseline-v1', 'efficient-v2')]
    [string]$CeilingExpectedAgentPolicy = 'neutral-v1',
    [ValidateSet('legacy-unversioned', 'upstream-static-v1')]
    [string]$CoreExpectedAgentToolchain = 'upstream-static-v1',
    [ValidateSet('legacy-unversioned', 'upstream-static-v1')]
    [string]$CeilingExpectedAgentToolchain = 'upstream-static-v1',
    [ValidateRange(0, 1048576)][int]$CoreExpectedToolOutputMaxBytes = 16384,
    [ValidateRange(0, 1048576)][int]$CeilingExpectedToolOutputMaxBytes = 16384
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$stateDirectory = Join-Path $projectRoot '.runpod\cybench-supervisor'
$statePath = Join-Path $stateDirectory 'state.json'
$stopRequestPath = Join-Path $stateDirectory 'stop.request.json'
$workerPath = Join-Path $PSScriptRoot 'cybench-supervisor-worker.ps1'
$watchdogPath = Join-Path $PSScriptRoot 'cybench-supervisor-watchdog.ps1'
$expectedModel = 'openai-api/llamacpp/qwen3.8-27b-uncensored-q6'
$expectedModelContextTokens = 262144
[IO.Directory]::CreateDirectory($stateDirectory) | Out-Null

function Invoke-BoundedInspectTaskList {
    $inspect = '/home/qwen-eval/.local/share/qwen-eval/.venv/bin/inspect'
    $output = & wsl.exe -d Ubuntu-24.04 -- /usr/bin/timeout `
        --signal=TERM --kill-after=5s 25s $inspect ctl task list --json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to read the live Inspect task set.'
    }
    $text = (@($output) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'Inspect task discovery returned no JSON.'
    }
    return ($text | ConvertFrom-Json)
}

function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$WindowsPath)
    $fullPath = [IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -notmatch '^(?<drive>[A-Za-z]):\\(?<tail>.*)$') {
        throw "Cannot convert path to WSL: $fullPath"
    }
    return '/mnt/' + $Matches.drive.ToLowerInvariant() + '/' + $Matches.tail.Replace('\', '/')
}

function Get-ExactLiveCoreTask {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$ResolvedLogDirectory
    )

    $payload = Invoke-BoundedInspectTaskList
    $liveCybench = @($payload.tasks | Where-Object {
        $_.task -eq 'cybench_isolated' -and $null -eq $_.completed_at
    })
    $expectedWslLogDirectory = (
        ConvertTo-WslPath -WindowsPath $ResolvedLogDirectory
    ).TrimEnd('/')
    $matches = @($liveCybench | Where-Object {
        if (
            [string]$_.task_id -ne $TaskId -or
            [string]$_.model -ne $expectedModel -or
            $null -eq $_.PSObject.Properties['pid'] -or
            [int]$_.pid -le 0
        ) {
            return $false
        }
        $actualLog = [string]$_.log_location
        $separator = $actualLog.LastIndexOf('/')
        if ($separator -le 0) {
            return $false
        }
        $actualLogDirectory = $actualLog.Substring(0, $separator).TrimEnd('/')
        return [string]::Equals(
            $actualLogDirectory,
            $expectedWslLogDirectory,
            [StringComparison]::Ordinal
        )
    })
    if ($liveCybench.Count -ne 1 -or $matches.Count -ne 1) {
        throw (
            'The requested Core task is not the sole exact live Cybench task ' +
            '(task id, positive PID, model, and log directory must all match).'
        )
    }
    return $matches[0]
}

function Invoke-BoundedCoreHealth {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & wsl.exe -d Ubuntu-24.04 @Arguments 2>&1
    return [pscustomobject]@{
        exit_code = $LASTEXITCODE
        text = (@($output) -join "`n").Trim()
    }
}

function Assert-LiveCoreRunContract {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$ResolvedLogDirectory
    )

    $wslProjectRoot = ConvertTo-WslPath -WindowsPath $projectRoot
    $healthArguments = @(
        '--cd', $wslProjectRoot,
        '--',
        '/usr/bin/env', "PYTHONPATH=$wslProjectRoot",
        '/usr/bin/timeout', '--signal=TERM', '--kill-after=5s', '30s',
        '/home/qwen-eval/.local/share/qwen-eval/.venv/bin/python',
        "$wslProjectRoot/scripts/cybench_run_health.py",
        (ConvertTo-WslPath -WindowsPath $ResolvedLogDirectory),
        '--expected-samples', '8',
        '--expected-model', $expectedModel,
        '--expected-profile', 'core',
        '--expected-task-id', $TaskId,
        '--expected-agent-policy', $CoreExpectedAgentPolicy,
        '--expected-agent-toolchain', $CoreExpectedAgentToolchain,
        '--expected-model-api-timeout-policy', $ExpectedModelApiTimeoutPolicy,
        '--expected-model-api-client-timeout-seconds', [string]$ExpectedModelApiClientTimeoutSeconds,
        '--expected-documentation-pipeline-id', 'iterative-active-window',
        '--expected-documentation-pipeline-version', '3',
        '--expected-context-management', 'summary_compaction',
        '--expected-compaction-threshold-tokens', [string]$CoreExpectedCompactionThresholdTokens,
        '--expected-compaction-summary-max-tokens', '4096',
        '--expected-model-context-tokens', [string]$expectedModelContextTokens
    )
    if ($CoreExpectedToolOutputMaxBytes -gt 0) {
        $healthArguments += @(
            '--expected-tool-output-max-bytes',
            [string]$CoreExpectedToolOutputMaxBytes
        )
    }

    $lastState = $null
    for ($attempt = 0; $attempt -lt 3; $attempt += 1) {
        $probe = Invoke-BoundedCoreHealth -Arguments $healthArguments
        $exitCode = [int]$probe.exit_code
        $text = [string]$probe.text
        $health = $null
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            try {
                $health = $text | ConvertFrom-Json
                $lastState = [string]$health.state
            }
            catch {
                $lastState = 'unreadable'
            }
        }
        if ($exitCode -eq 0 -and $null -ne $health -and $lastState -eq 'running') {
            return
        }
        if ($lastState -in @('technical_error', 'incomplete', 'complete', 'ambiguous')) {
            break
        }
        if ($attempt -lt 2) {
            Start-Sleep -Seconds 2
        }
    }
    throw (
        'The live Core log does not match the required running Core policy, ' +
        'toolchain, sample, documentation, and compaction contract.'
    )
}

function Get-StateValue {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Path
    )
    $current = $State
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) {
            return $null
        }
        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) {
            return $null
        }
        $current = $property.Value
    }
    return $current
}

function Get-ContractMismatches {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$ResolvedLogDirectory
    )
    $expected = [ordered]@{
        'schema_version' = 1
        'desired_state' = 'running'
        'expected_model' = $expectedModel
        'expected_model_context_tokens' = $expectedModelContextTokens
        'expected_model_api_timeout_policy' = $ExpectedModelApiTimeoutPolicy
        'expected_model_api_client_timeout_seconds' = $ExpectedModelApiClientTimeoutSeconds
        'poll_seconds' = $PollSeconds
        'final_health_timeout_seconds' = $FinalHealthTimeoutSeconds
        'core.task_id' = $CoreTaskId
        'core.log_directory' = $ResolvedLogDirectory
        'core.expected_compaction_threshold_tokens' = $CoreExpectedCompactionThresholdTokens
        'core.expected_agent_policy' = $CoreExpectedAgentPolicy
        'core.expected_agent_toolchain' = $CoreExpectedAgentToolchain
        'core.expected_tool_output_max_bytes' = $CoreExpectedToolOutputMaxBytes
        'ceiling.expected_compaction_threshold_tokens' = $CeilingExpectedCompactionThresholdTokens
        'ceiling.expected_agent_policy' = $CeilingExpectedAgentPolicy
        'ceiling.expected_agent_toolchain' = $CeilingExpectedAgentToolchain
        'ceiling.expected_tool_output_max_bytes' = $CeilingExpectedToolOutputMaxBytes
    }
    $mismatches = [Collections.Generic.List[string]]::new()
    foreach ($entry in $expected.GetEnumerator()) {
        $actualValue = Get-StateValue -State $State -Path ([string]$entry.Key)
        if ([string]$entry.Key -eq 'core.log_directory') {
            $equal = [string]::Equals(
                ([string]$actualValue).TrimEnd('\'),
                ([string]$entry.Value).TrimEnd('\'),
                [StringComparison]::OrdinalIgnoreCase
            )
        }
        else {
            $equal = [string]::Equals(
                [string]$actualValue,
                [string]$entry.Value,
                [StringComparison]::Ordinal
            )
        }
        if (-not $equal) {
            [void]$mismatches.Add([string]$entry.Key)
        }
    }
    if (Test-Path -LiteralPath $stopRequestPath -PathType Leaf) {
        [void]$mismatches.Add('pending_stop_request')
    }
    return @($mismatches)
}

$hasCoreTaskId = -not [string]::IsNullOrWhiteSpace($CoreTaskId)
$hasCoreLogDirectory = -not [string]::IsNullOrWhiteSpace($CoreLogDirectory)
if ($hasCoreTaskId -ne $hasCoreLogDirectory) {
    throw 'Provide both CoreTaskId and CoreLogDirectory, or neither.'
}

if (-not $hasCoreTaskId) {
    $tasks = @((Invoke-BoundedInspectTaskList).tasks | Where-Object {
        $_.task -eq 'cybench_isolated' -and
        $_.model -eq 'openai-api/llamacpp/qwen3.8-27b-uncensored-q6' -and
        $null -eq $_.completed_at
    })
    if ($tasks.Count -ne 1) {
        throw "Expected exactly one live Q6 Cybench task, found $($tasks.Count)."
    }
    $CoreTaskId = [string]$tasks[0].task_id
    $wslLog = [string]$tasks[0].log_location
    if ($wslLog -notmatch '^/mnt/(?<drive>[a-zA-Z])/(?<tail>.*)/[^/]+\.eval$') {
        throw "Unexpected Inspect log path: $wslLog"
    }
    $CoreLogDirectory = $Matches.drive.ToUpperInvariant() + ':\' + ($Matches.tail -replace '/', '\')
}

$resolvedLogDirectory = (Resolve-Path -LiteralPath $CoreLogDirectory).Path

$existingState = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $liveWorkerFound = $false
    try {
        $existing = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
        $existingState = $existing
        $workerPid = [int](Get-StateValue -State $existing -Path 'worker_pid')
        $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $workerPid" -ErrorAction SilentlyContinue
        $existingNonce = [string](Get-StateValue -State $existing -Path 'startup_nonce')
        if (
            $null -ne $process -and
            ([string]$process.CommandLine).Contains('cybench-supervisor-worker.ps1') -and
            -not [string]::IsNullOrWhiteSpace($existingNonce) -and
            ([string]$process.CommandLine).Contains($existingNonce)
        ) {
            $liveWorkerFound = $true
            $mismatches = @(Get-ContractMismatches -State $existing -ResolvedLogDirectory $resolvedLogDirectory)
            if ($mismatches.Count -ne 0) {
                throw (
                    'A Cybench supervisor is already running with a different contract: ' +
                    ($mismatches -join ', ')
                )
            }
            $existingWatchdogNonce = [string](Get-StateValue -State $existing -Path 'watchdog_nonce')
            $watchdogPid = [int](Get-StateValue -State $existing -Path 'watchdog_pid')
            $watchdogProcess = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $watchdogPid" -ErrorAction SilentlyContinue
            if (
                [string]::IsNullOrWhiteSpace($existingNonce) -or
                [string]::IsNullOrWhiteSpace($existingWatchdogNonce) -or
                $null -eq $watchdogProcess -or
                ([string]$watchdogProcess.CommandLine).IndexOf(
                    $watchdogPath,
                    [StringComparison]::OrdinalIgnoreCase
                ) -lt 0 -or
                -not ([string]$watchdogProcess.CommandLine).Contains($existingNonce) -or
                -not ([string]$watchdogProcess.CommandLine).Contains($existingWatchdogNonce)
            ) {
                throw 'The live supervisor worker has no exact bound watchdog.'
            }
            $validatedExistingTask = Get-ExactLiveCoreTask `
                -TaskId $CoreTaskId `
                -ResolvedLogDirectory $resolvedLogDirectory
            Assert-LiveCoreRunContract `
                -TaskId $CoreTaskId `
                -ResolvedLogDirectory $resolvedLogDirectory
            if (
                [int](Get-StateValue -State $existing -Path 'core.inspect_pid') -ne
                [int]$validatedExistingTask.pid
            ) {
                throw 'The live supervisor state is not bound to the current exact Inspect PID.'
            }
            Write-Host "Cybench supervisor already running with the exact requested contract (PID $workerPid)."
            return
        }
    }
    catch {
        if ($liveWorkerFound) {
            throw
        }
        throw 'Existing supervisor state is unreadable; refusing to create a new plan implicitly.'
    }
}

$existingPlanIsTerminal = (
    $null -eq $existingState -or
    (
        [string]$existingState.desired_state -eq 'stopped' -and
        [string]$existingState.state -eq 'supervisor_stopped'
    ) -or
    (
        [string]$existingState.desired_state -eq 'complete' -and
        [string]$existingState.state -eq 'complete'
    )
)
if (-not $existingPlanIsTerminal) {
    throw (
        'An unfinished supervisor plan exists without its exact live worker. ' +
        'Resolve or explicitly clean up that plan before starting another.'
    )
}

$unboundWorkers = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    [string]$_.Name -in @('powershell.exe', 'pwsh.exe') -and
    ([string]$_.CommandLine).Contains('cybench-supervisor-worker.ps1')
})
if ($unboundWorkers.Count -ne 0) {
    throw 'A Cybench supervisor worker is running without a reusable exact state contract.'
}

# Both auto-discovery and explicit adoption pass through the same final,
# bounded tuple check. This is the ownership boundary for the new worker.
$validatedCoreTask = Get-ExactLiveCoreTask `
    -TaskId $CoreTaskId `
    -ResolvedLogDirectory $resolvedLogDirectory
Assert-LiveCoreRunContract `
    -TaskId $CoreTaskId `
    -ResolvedLogDirectory $resolvedLogDirectory
$coreInspectPid = [int]$validatedCoreTask.pid

$stdoutPath = Join-Path $stateDirectory 'worker.stdout.log'
$stderrPath = Join-Path $stateDirectory 'worker.stderr.log'
# A request left by an already-finished plan must not stop the next plan. Clear
# it while no worker exists; every request created after this point is owned by
# the worker we are about to start and must not be deleted by that worker.
Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue
$startupNonce = [guid]::NewGuid().ToString('N')
$argumentLine = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', ('"' + $workerPath + '"'),
    '-CoreTaskId', $CoreTaskId,
    '-CoreInspectPid', [string]$coreInspectPid,
    '-CoreLogDirectory', ('"' + $resolvedLogDirectory + '"'),
    '-StartupNonce', $startupNonce,
    '-PollSeconds', [string]$PollSeconds,
    '-FinalHealthTimeoutSeconds', [string]$FinalHealthTimeoutSeconds,
    '-ExpectedModelApiTimeoutPolicy', $ExpectedModelApiTimeoutPolicy,
    '-ExpectedModelApiClientTimeoutSeconds', [string]$ExpectedModelApiClientTimeoutSeconds,
    '-CoreExpectedCompactionThresholdTokens', [string]$CoreExpectedCompactionThresholdTokens,
    '-CeilingExpectedCompactionThresholdTokens', [string]$CeilingExpectedCompactionThresholdTokens,
    '-CoreExpectedAgentPolicy', $CoreExpectedAgentPolicy,
    '-CeilingExpectedAgentPolicy', $CeilingExpectedAgentPolicy,
    '-CoreExpectedAgentToolchain', $CoreExpectedAgentToolchain,
    '-CeilingExpectedAgentToolchain', $CeilingExpectedAgentToolchain,
    '-CoreExpectedToolOutputMaxBytes', [string]$CoreExpectedToolOutputMaxBytes,
    '-CeilingExpectedToolOutputMaxBytes', [string]$CeilingExpectedToolOutputMaxBytes
) -join ' '

$process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

$workerBound = $false
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 250
        if ($process.HasExited) {
            $errorText = if (Test-Path -LiteralPath $stderrPath) { (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue) } else { '' }
            throw "Cybench supervisor exited during startup (code $($process.ExitCode)). $errorText"
        }
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            try {
                $state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
                if (
                    [int]$state.worker_pid -eq $process.Id -and
                    [string]::Equals(
                        [string](Get-StateValue -State $state -Path 'startup_nonce'),
                        $startupNonce,
                        [StringComparison]::Ordinal
                    ) -and
                    [int](Get-StateValue -State $state -Path 'watchdog_pid') -gt 0
                ) {
                    $watchdogPid = [int](Get-StateValue -State $state -Path 'watchdog_pid')
                    $watchdogNonce = [string](Get-StateValue -State $state -Path 'watchdog_nonce')
                    $watchdogProcess = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $watchdogPid" -ErrorAction SilentlyContinue
                    if (
                        -not [string]::IsNullOrWhiteSpace($watchdogNonce) -and
                        $null -ne $watchdogProcess -and
                        ([string]$watchdogProcess.CommandLine).IndexOf(
                            $watchdogPath,
                            [StringComparison]::OrdinalIgnoreCase
                        ) -ge 0 -and
                        ([string]$watchdogProcess.CommandLine).Contains($startupNonce) -and
                        ([string]$watchdogProcess.CommandLine).Contains($watchdogNonce)
                    ) {
                        $workerBound = $true
                        Write-Host "Cybench supervisor started (PID $($process.Id), watchdog PID $watchdogPid)."
                        Write-Host "State: $statePath"
                        return
                    }
                }
            }
            catch {
                # Retry while the worker performs its first atomic write.
            }
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Cybench supervisor did not publish its state within 15 seconds.'
}
finally {
    if (-not $workerBound -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        try {
            $process.WaitForExit(5000)
        }
        catch {
            # The exact startup worker was already stopped or is exiting.
        }
    }
}

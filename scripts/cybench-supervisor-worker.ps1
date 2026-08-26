param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9]+$')][string]$CoreTaskId,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$CoreInspectPid,
    [Parameter(Mandatory)][string]$CoreLogDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$StartupNonce,
    [ValidateRange(10, 300)][int]$PollSeconds = 30,
    [ValidateRange(60, 3600)][int]$FinalHealthTimeoutSeconds = 900,
    [string]$ExpectedModel = 'openai-api/llamacpp/qwen3.8-27b-uncensored-q6',
    [ValidateRange(4096, 262144)][int]$ExpectedModelContextTokens = 262144,
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
Import-Module (Join-Path $PSScriptRoot 'RunPod.Common.psm1') -Force

$projectRoot = Split-Path -Parent $PSScriptRoot
$stateDirectory = Join-Path $projectRoot '.runpod\cybench-supervisor'
$statePath = Join-Path $stateDirectory 'state.json'
$previousStatePath = Join-Path $stateDirectory 'state.previous.json'
$lockPath = Join-Path $stateDirectory 'worker.lock'
$stopRequestPath = Join-Path $stateDirectory 'stop.request.json'
$eventsPath = Join-Path $stateDirectory 'events.ndjson'
$eventsArchiveDirectory = Join-Path $stateDirectory 'events-archive'
$watchdogPath = Join-Path $PSScriptRoot 'cybench-supervisor-watchdog.ps1'
$watchdogStatePath = Join-Path $stateDirectory 'watchdog.json'
$inspectBinary = '/home/qwen-eval/.local/share/qwen-eval/.venv/bin/inspect'
$pythonBinary = '/home/qwen-eval/.local/share/qwen-eval/.venv/bin/python'
$expectedCounts = @{ core = 8; ceiling = 4 }
$transientHealthReasons = @(
    'endpoint_check_failed',
    'gpu_telemetry_failed',
    'ctl_poll_failed',
    'sample_poll_failed'
)

[IO.Directory]::CreateDirectory($stateDirectory) | Out-Null

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class QwenEvalPowerState {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint flags);
}
'@

function Get-UtcTimestamp {
    return [DateTime]::UtcNow.ToString('o')
}

function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$WindowsPath)
    $fullPath = [IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -notmatch '^(?<drive>[A-Za-z]):\\(?<tail>.*)$') {
        throw "Cannot convert path to WSL: $fullPath"
    }
    return '/mnt/' + $Matches.drive.ToLowerInvariant() + '/' + $Matches.tail.Replace('\', '/')
}

function ConvertFrom-WslPath {
    param([Parameter(Mandatory)][string]$WslPath)
    if ($WslPath -notmatch '^/mnt/(?<drive>[a-zA-Z])/(?<tail>.*)$') {
        throw "Unexpected WSL path: $WslPath"
    }
    return $Matches.drive.ToUpperInvariant() + ':\' + $Matches.tail.Replace('/', '\')
}

function Get-LaunchIdFromLogDirectory {
    param([Parameter(Mandatory)][string]$LogDirectory)
    $directoryName = Split-Path -Leaf $LogDirectory.TrimEnd('\', '/')
    if ($directoryName -notmatch '^(?<id>[A-Za-z0-9-]+)-cybench$') {
        throw "Cybench log directory has no valid launch id: $LogDirectory"
    }
    return [string]$Matches.id
}

function Get-SafeError {
    param([Parameter(Mandatory)]$ErrorRecord)
    $message = [string]$ErrorRecord.Exception.Message
    if ($message.Length -gt 300) {
        $message = $message.Substring(0, 300)
    }
    return [ordered]@{
        type = $ErrorRecord.Exception.GetType().Name
        message = $message
        at_utc = Get-UtcTimestamp
    }
}

function Set-TransientHealthIssue {
    param(
        [Parameter(Mandatory)][ValidateSet(
            'endpoint_check_failed',
            'gpu_telemetry_failed',
            'ctl_poll_failed',
            'sample_poll_failed'
        )][string]$Reason,
        [Parameter(Mandatory)]$ErrorRecord
    )

    $issue = [ordered]@{
        reason = $Reason
        detail = Get-SafeError $ErrorRecord
        at_utc = Get-UtcTimestamp
    }
    $script:state.health.active_transient_issues[$Reason] = $issue
    if (
        $null -eq $script:state.last_issue -or
        $transientHealthReasons -contains [string]$script:state.last_issue.reason
    ) {
        $script:state.last_issue = $issue
    }
}

function Get-LatestTransientHealthIssue {
    $remaining = @(
        $script:state.health.active_transient_issues.GetEnumerator() |
            Sort-Object { [string]$_.Value.at_utc } |
            Select-Object -Last 1
    )
    if ($remaining.Count -eq 1) {
        return $remaining[0].Value
    }
    return $null
}

function Clear-TransientHealthIssue {
    param(
        [Parameter(Mandatory)][ValidateSet(
            'endpoint_check_failed',
            'gpu_telemetry_failed',
            'ctl_poll_failed',
            'sample_poll_failed'
        )][string]$Reason
    )

    [void]$script:state.health.active_transient_issues.Remove($Reason)
    if (
        $null -ne $script:state.last_issue -and
        [string]$script:state.last_issue.reason -eq $Reason
    ) {
        $script:state.last_issue = Get-LatestTransientHealthIssue
    }
}

function Write-EventRecord {
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Data = @{}
    )
    $record = [ordered]@{
        schema_version = 1
        plan_id = [string]$script:state.plan_id
        at_utc = Get-UtcTimestamp
        event = $Name
        data = $Data
    }
    Add-Content -LiteralPath $eventsPath -Value ($record | ConvertTo-Json -Compress -Depth 6) -Encoding utf8
}

function Archive-ExistingEventLog {
    if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) {
        return $null
    }
    $existingFile = Get-Item -LiteralPath $eventsPath
    if ($existingFile.Length -eq 0) {
        Remove-Item -LiteralPath $eventsPath -Force
        return $null
    }

    $previousPlanId = 'legacy-unversioned'
    try {
        $firstRecord = Get-Content -LiteralPath $eventsPath -Encoding utf8 |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Select-Object -First 1 |
            ConvertFrom-Json
        if (
            $null -ne $firstRecord -and
            [string]$firstRecord.plan_id -match '^[0-9a-fA-F-]{36}$'
        ) {
            $previousPlanId = ([string]$firstRecord.plan_id).ToLowerInvariant()
        }
    }
    catch {
        # Pre-provenance event files are intentionally archived under the
        # explicit legacy label instead of being discarded or rewritten.
    }

    [IO.Directory]::CreateDirectory($eventsArchiveDirectory) | Out-Null
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')
    $archivePath = Join-Path $eventsArchiveDirectory (
        "events-$previousPlanId-$timestamp.ndjson"
    )
    Move-Item -LiteralPath $eventsPath -Destination $archivePath
    return $archivePath
}

function Save-State {
    $script:state.sequence = [int]$script:state.sequence + 1
    $script:state.updated_at_utc = Get-UtcTimestamp
    $json = $script:state | ConvertTo-Json -Depth 10
    $temporaryPath = "$statePath.$PID.tmp"
    [IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        [IO.File]::Replace($temporaryPath, $statePath, $previousStatePath, $true)
    }
    else {
        [IO.File]::Move($temporaryPath, $statePath)
    }
}

function Test-StopRequested {
    if (
        $null -eq $script:state -or
        -not (Test-Path -LiteralPath $stopRequestPath -PathType Leaf)
    ) {
        return $false
    }
    try {
        $request = Get-Content -LiteralPath $stopRequestPath -Raw -Encoding utf8 | ConvertFrom-Json
        return (
            [string]$request.action -eq 'stop_supervisor_only' -and
            [string]::Equals(
                [string]$request.plan_id,
                [string]$script:state.plan_id,
                [StringComparison]::Ordinal
            ) -and
            [string]::Equals(
                [string]$request.startup_nonce,
                $StartupNonce,
                [StringComparison]::Ordinal
            )
        )
    }
    catch {
        return $false
    }
}

function Test-ExactWatchdogProcess {
    param([int]$ProcessId)
    if ($ProcessId -le 0) {
        return $false
    }
    $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return $false
    }
    $commandLine = [string]$process.CommandLine
    $watchdogNonce = [string]$script:state.watchdog_nonce
    return (
        $commandLine.IndexOf($watchdogPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $commandLine.Contains($StartupNonce) -and
        -not [string]::IsNullOrWhiteSpace($watchdogNonce) -and
        $commandLine.Contains($watchdogNonce) -and
        $commandLine.Contains([string]$PID)
    )
}

function Test-WatchdogHeartbeatFresh {
    param([int]$ProcessId)
    try {
        if (-not (Test-Path -LiteralPath $watchdogStatePath -PathType Leaf)) {
            return $false
        }
        $watchdogState = Get-Content -LiteralPath $watchdogStatePath -Raw -Encoding utf8 | ConvertFrom-Json
        if (
            [int]$watchdogState.watchdog_pid -ne $ProcessId -or
            -not [string]::Equals(
                [string]$watchdogState.watchdog_nonce,
                [string]$script:state.watchdog_nonce,
                [StringComparison]::Ordinal
            )
        ) {
            return $false
        }
        $updatedAt = [DateTime]::Parse(
            [string]$watchdogState.updated_at_utc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        $maximumAgeSeconds = [Math]::Max(180, $PollSeconds * 4)
        return ([DateTime]::UtcNow - $updatedAt).TotalSeconds -le $maximumAgeSeconds
    }
    catch {
        return $false
    }
}

function Ensure-SupervisorWatchdog {
    $currentPid = if ($null -ne $script:state.watchdog_pid) {
        [int]$script:state.watchdog_pid
    }
    else {
        0
    }
    $currentProcessIsExact = Test-ExactWatchdogProcess -ProcessId $currentPid
    if (
        $currentProcessIsExact -and
        (Test-WatchdogHeartbeatFresh -ProcessId $currentPid)
    ) {
        return
    }

    if ($currentProcessIsExact) {
        Stop-Process -Id $currentPid -Force -ErrorAction SilentlyContinue
        try {
            $staleWatchdog = Get-Process -Id $currentPid -ErrorAction SilentlyContinue
            if ($null -ne $staleWatchdog) {
                [void]$staleWatchdog.WaitForExit(5000)
            }
        }
        catch {
            # The exact stale watchdog already exited or is being reaped.
        }
    }

    $newWatchdogNonce = [guid]::NewGuid().ToString('N')
    $script:state.watchdog_pid = $null
    $script:state.watchdog_nonce = $newWatchdogNonce
    Save-State
    $watchdogStdoutPathForLaunch = Join-Path $stateDirectory "watchdog-$newWatchdogNonce.stdout.log"
    $watchdogStderrPathForLaunch = Join-Path $stateDirectory "watchdog-$newWatchdogNonce.stderr.log"
    $argumentLine = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $watchdogPath + '"'),
        '-WorkerPid', [string]$PID,
        '-StartupNonce', $StartupNonce,
        '-WatchdogNonce', $newWatchdogNonce,
        '-PollSeconds', [string]$PollSeconds
    ) -join ' '
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput $watchdogStdoutPathForLaunch `
        -RedirectStandardError $watchdogStderrPathForLaunch
    $bound = $false
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 200
            if ($process.HasExited) {
                throw "Supervisor watchdog exited during startup (code $($process.ExitCode))."
            }
            if (Test-Path -LiteralPath $watchdogStatePath -PathType Leaf) {
                try {
                    $watchdogState = Get-Content -LiteralPath $watchdogStatePath -Raw -Encoding utf8 | ConvertFrom-Json
                    if (
                        [int]$watchdogState.watchdog_pid -eq $process.Id -and
                        [int]$watchdogState.worker_pid -eq $PID -and
                        [string]::Equals(
                            [string]$watchdogState.startup_nonce,
                            $StartupNonce,
                            [StringComparison]::Ordinal
                        ) -and
                        [string]::Equals(
                            [string]$watchdogState.watchdog_nonce,
                            $newWatchdogNonce,
                            [StringComparison]::Ordinal
                        )
                    ) {
                        $bound = $true
                        $script:state.watchdog_pid = $process.Id
                        $script:state.watchdog_nonce = $newWatchdogNonce
                        Save-State
                        return
                    }
                }
                catch {
                    # Retry while the watchdog performs its atomic first write.
                }
            }
        } while ([DateTime]::UtcNow -lt $deadline)
        throw 'Supervisor watchdog did not publish its state within 10 seconds.'
    }
    finally {
        if (-not $bound -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-InspectJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    # A wedged control endpoint must not wedge the monitor itself. Every read
    # is bounded; the next poll can recover without touching the eval.
    $output = & wsl.exe -d Ubuntu-24.04 -- /usr/bin/timeout `
        --signal=TERM --kill-after=5s 25s $inspectBinary @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = (@($output) -join "`n").Trim()
    if ($exitCode -ne 0) {
        throw "Inspect control command failed with exit code $exitCode."
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'Inspect control command returned no JSON.'
    }
    return ($text | ConvertFrom-Json)
}

function Get-RunningTasks {
    $response = Invoke-InspectJson -Arguments @('ctl', 'task', 'list', '--json')
    return @($response.tasks)
}

function Get-SampleProgress {
    param([Parameter(Mandatory)][string]$TaskId)
    return Invoke-InspectJson -Arguments @('ctl', 'sample', 'list', $TaskId, '--all', '--json')
}

function Get-PagedSampleEvents {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$SampleId,
        [Parameter(Mandatory)][int]$Epoch,
        [Parameter(Mandatory)][string]$Type,
        [switch]$FromStart,
        [string]$SinceTime,
        [switch]$Full,
        [ValidateRange(1, 5000)][int]$Limit = 500,
        [ValidateRange(1, 100)][int]$MaxPages = 20
    )

    if ($FromStart -and -not [string]::IsNullOrWhiteSpace($SinceTime)) {
        throw 'Event pagination cannot combine FromStart and SinceTime.'
    }
    $events = New-Object 'System.Collections.Generic.List[object]'
    $cursor = $null
    $terminalDone = $false
    $caughtUp = $false
    $pageCount = 0
    while ($pageCount -lt $MaxPages) {
        if (Test-StopRequested) {
            throw [OperationCanceledException]::new(
                'Supervisor stop requested during event pagination.'
            )
        }
        $arguments = @(
            'ctl', 'sample', 'events', $TaskId, $SampleId, [string]$Epoch
        )
        if ($null -ne $cursor) {
            $arguments += @('--cursor', [string]$cursor)
        }
        elseif ($FromStart) {
            $arguments += '--from-start'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($SinceTime)) {
            $arguments += @('--since-time', $SinceTime)
        }
        $arguments += @('--type', $Type, '--limit', [string]$Limit)
        if ($Full) {
            $arguments += '--full'
        }
        $arguments += '--json'

        Ensure-SupervisorWatchdog
        Save-State
        $page = Invoke-InspectJson -Arguments $arguments
        Save-State
        if (Test-StopRequested) {
            throw [OperationCanceledException]::new(
                'Supervisor stop requested during event pagination.'
            )
        }
        foreach ($event in @($page.events)) {
            $events.Add($event)
        }
        $pageCount += 1
        $terminalDone = [bool]$page.done
        $nextCursor = [string]$page.next
        if ($terminalDone) {
            $caughtUp = $true
            $cursor = $nextCursor
            break
        }
        if ([string]::IsNullOrWhiteSpace($nextCursor)) {
            throw 'Inspect event page omitted its continuation cursor.'
        }
        # A live sample is not terminal (done=false), so one empty poll at the
        # current cursor is the authoritative indication that we caught up to
        # its present transcript snapshot.
        if ($null -ne $cursor -and $nextCursor -eq $cursor) {
            $caughtUp = $true
            break
        }
        $cursor = $nextCursor
    }
    if (-not $caughtUp) {
        throw "Inspect event pagination exceeded $MaxPages pages."
    }
    return [pscustomobject][ordered]@{
        events = @($events.ToArray())
        page_count = $pageCount
        caught_up = $caughtUp
        terminal_done = $terminalDone
        next = $cursor
    }
}

function Get-CompactionTelemetry {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$SampleId,
        [Parameter(Mandatory)][int]$Epoch
    )

    # Metadata-only control reads are deliberate: they expose timing and
    # structure without copying agent-controlled prose into supervisor state.
    $history = Get-PagedSampleEvents `
        -TaskId $TaskId `
        -SampleId $SampleId `
        -Epoch $Epoch `
        -Type 'compaction' `
        -FromStart `
        -Full
    $events = @($history.events)
    $invalidEvents = 0
    foreach ($event in $events) {
        $metadata = $event.metadata
        if (
            $event.type -ne 'summary' -or
            $null -eq $metadata -or
            [int64]$event.tokens_before -le [int64]$event.tokens_after -or
            [int]$metadata.messages_before -le [int]$metadata.messages_after
        ) {
            $invalidEvents += 1
        }
    }

    $latest = @($events | Sort-Object {
        [DateTimeOffset]::Parse(
            [string]$_.timestamp,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal
        )
    } | Select-Object -Last 1)
    $continuation = 'not_applicable'
    $latestRecord = $null
    if ($latest.Count -eq 1) {
        $latestEvent = $latest[0]
        $latestTimestamp = (
            [DateTimeOffset]::Parse(
                [string]$latestEvent.timestamp,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal
            ).ToUnixTimeMilliseconds() / 1000.0
        )
        $laterHistory = Get-PagedSampleEvents `
            -TaskId $TaskId `
            -SampleId $SampleId `
            -Epoch $Epoch `
            -Type 'model,tool,error' `
            -SinceTime $latestTimestamp.ToString(
                'R', [Globalization.CultureInfo]::InvariantCulture
            )
        $laterEvents = @($laterHistory.events | Where-Object {
            [double]$_.timestamp -gt $latestTimestamp
        })
        if (@($laterEvents | Where-Object { $_.event -eq 'error' }).Count -gt 0) {
            $continuation = 'error_after_compaction'
        }
        elseif (@($laterEvents | Where-Object { $_.event -in @('model', 'tool') }).Count -gt 0) {
            $continuation = 'continuation_started'
        }
        else {
            $continuation = 'awaiting_continuation'
        }
        $latestRecord = [ordered]@{
            timestamp_utc = [string]$latestEvent.timestamp
            timestamp_unix = $latestTimestamp
            tokens_before = [int64]$latestEvent.tokens_before
            tokens_after = [int64]$latestEvent.tokens_after
            messages_before = [int]$latestEvent.metadata.messages_before
            messages_after = [int]$latestEvent.metadata.messages_after
            trigger = [string]$latestEvent.metadata.trigger
        }
    }

    return [ordered]@{
        count = $events.Count
        invalid_event_count = $invalidEvents
        complete_event_history = [bool]$history.terminal_done
        history_caught_up = [bool]$history.caught_up
        history_page_count = [int]$history.page_count
        latest = $latestRecord
        structural_continuation = $continuation
        semantic_continuity = if ($events.Count -gt 0) { 'post_run_review_required' } else { 'not_applicable' }
        checked_at_utc = Get-UtcTimestamp
    }
}

function Get-GpuTelemetry {
    # Both SSH liveness and the remote command are bounded. This probe is
    # read-only and remains best-effort in Monitor-Stage.
    $session = Get-RunPodSession
    $remoteCommand = (
        'timeout --signal=TERM --kill-after=2s 10s ' +
        'nvidia-smi --query-gpu=memory.total,memory.used,memory.free,' +
        'utilization.gpu,temperature.gpu,power.draw ' +
        '--format=csv,noheader,nounits'
    )
    $output = @(Invoke-RunPodSshBounded `
        -Session $session `
        -RemoteCommand $remoteCommand `
        -TimeoutSeconds 40)
    if ($output.Count -ne 1) {
        throw "Expected one GPU telemetry row, received $($output.Count)."
    }
    $fields = @(([string]$output[0]).Split(',') | ForEach-Object { $_.Trim() })
    if ($fields.Count -ne 6) {
        throw "Expected six GPU telemetry fields, received $($fields.Count)."
    }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $styles = [Globalization.NumberStyles]::Float
    $values = @()
    foreach ($field in $fields) {
        $parsed = 0.0
        if (-not [double]::TryParse($field, $styles, $culture, [ref]$parsed)) {
            throw 'GPU telemetry contained a non-numeric field.'
        }
        $values += $parsed
    }
    return [ordered]@{
        memory_total_mib = [int64][Math]::Round($values[0])
        memory_used_mib = [int64][Math]::Round($values[1])
        memory_free_mib = [int64][Math]::Round($values[2])
        utilization_percent = [double]$values[3]
        temperature_c = [double]$values[4]
        power_draw_w = [double]$values[5]
        checked_at_utc = Get-UtcTimestamp
    }
}

function Test-Endpoint {
    $session = Get-RunPodSession
    $session = Start-RunPodTunnel -Session $session
    Start-RunPodWslTunnel -Session $session
}

function Invoke-FinalHealth {
    param(
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][int]$ExpectedSamples,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$ExpectedCompactionThresholdTokens,
        [Parameter(Mandatory)][string]$ExpectedAgentPolicy,
        [Parameter(Mandatory)][string]$ExpectedAgentToolchain,
        [Parameter(Mandatory)][int]$ExpectedToolOutputMaxBytes,
        [Parameter(Mandatory)][ValidateRange(1, 300)][int]$ProbeTimeoutSeconds
    )
    $wslLogDirectory = ConvertTo-WslPath -WindowsPath $LogDirectory
    $wslProjectRoot = ConvertTo-WslPath -WindowsPath $projectRoot
    $healthArguments = @(
        '/usr/bin/env', "PYTHONPATH=$wslProjectRoot",
        $pythonBinary,
        (ConvertTo-WslPath -WindowsPath (Join-Path $PSScriptRoot 'cybench_run_health.py')),
        $wslLogDirectory,
        '--expected-samples', [string]$ExpectedSamples,
        '--expected-model', $ExpectedModel,
        '--expected-profile', $Profile,
        '--expected-task-id', $TaskId,
        '--expected-agent-policy', $ExpectedAgentPolicy,
        '--expected-agent-toolchain', $ExpectedAgentToolchain,
        '--expected-model-api-timeout-policy', $ExpectedModelApiTimeoutPolicy,
        '--expected-model-api-client-timeout-seconds', [string]$ExpectedModelApiClientTimeoutSeconds,
        '--expected-documentation-pipeline-id', 'iterative-active-window',
        '--expected-documentation-pipeline-version', '3',
        '--expected-context-management', 'summary_compaction',
        '--expected-compaction-threshold-tokens', [string]$ExpectedCompactionThresholdTokens,
        '--expected-compaction-summary-max-tokens', '4096',
        '--expected-model-context-tokens', [string]$ExpectedModelContextTokens
    )
    if ($ExpectedToolOutputMaxBytes -gt 0) {
        $healthArguments += @(
            '--expected-tool-output-max-bytes',
            [string]$ExpectedToolOutputMaxBytes
        )
    }
    $boundedHealthArguments = @(
        '/usr/bin/timeout',
        '--signal=TERM',
        '--kill-after=5s',
        "$($ProbeTimeoutSeconds)s"
    )
    $boundedHealthArguments += $healthArguments
    $output = & wsl.exe -d Ubuntu-24.04 --cd $projectRoot -- @boundedHealthArguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = (@($output) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'Final health check returned no JSON.'
    }
    $health = $text | ConvertFrom-Json
    return [ordered]@{ exit_code = $exitCode; result = $health }
}

function Set-Blocked {
    param(
        [Parameter(Mandatory)][string]$Reason,
        $Issue = $null
    )
    $script:state.state = 'attention_required'
    $script:state.last_issue = [ordered]@{
        reason = $Reason
        detail = $Issue
        at_utc = Get-UtcTimestamp
    }
    Save-State
    Write-EventRecord -Name 'attention_required' -Data @{ reason = $Reason }
}

function Invoke-MonitoringOutageContainment {
    param(
        [Parameter(Mandatory)]$Stage,
        [Parameter(Mandatory)][ValidateSet('core', 'ceiling')][string]$Profile,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][DateTime]$StartedAt
    )

    $issue = [ordered]@{
        profile = $Profile
        outage_started_at_utc = $StartedAt.ToString('o')
        grace_seconds = [int]$script:monitoringOutageGraceSeconds
    }
    if ($null -eq $Stage.integrity_block) {
        $Stage.integrity_block = [ordered]@{
            reason = $Reason
            detail = $issue
            at_utc = Get-UtcTimestamp
        }
    }
    Set-Blocked -Reason $Reason -Issue $issue
    Write-EventRecord -Name 'monitoring_outage_containment_started' -Data @{
        profile = $Profile
        reason = $Reason
    }

    try {
        $launchRecord = if (
            $null -ne $Stage.inspect_pid -and [int]$Stage.inspect_pid -gt 0
        ) {
            [pscustomobject]@{ pid = [int]$Stage.inspect_pid }
        }
        else {
            $null
        }
        Stop-DetachedLaunch `
            -LaunchRecord $launchRecord `
            -RegisteredTask ([pscustomobject]@{
                task_id = [string]$Stage.task_id
            }) `
            -ExpectedWslLogDirectory (
                ConvertTo-WslPath -WindowsPath ([string]$Stage.log_directory)
            ) `
            -Reason $Reason
        $Stage.status = 'blocked'
        Save-State
        Write-EventRecord -Name 'monitoring_outage_contained' -Data @{
            profile = $Profile
            reason = $Reason
        }
        return $true
    }
    catch {
        Set-Blocked `
            -Reason 'monitoring_outage_containment_failed' `
            -Issue (Get-SafeError $_)
        Write-EventRecord -Name 'monitoring_outage_containment_failed' -Data @{
            profile = $Profile
            reason = $Reason
        }
        return $false
    }
}

function Get-LaunchRecord {
    param(
        [Parameter(Mandatory)][object[]]$Output,
        [Parameter(Mandatory)][string]$ExpectedWslLogDirectory
    )

    $records = @()
    foreach ($line in $Output) {
        $candidate = ([string]$line).Trim()
        if (-not $candidate.StartsWith('{')) {
            continue
        }
        try {
            $parsed = $candidate | ConvertFrom-Json
            if (
                $null -ne $parsed.PSObject.Properties['event'] -and
                [string]$parsed.event -eq 'launch'
            ) {
                $records += $parsed
            }
        }
        catch {
            # Human-readable launcher output can contain braces. Only a valid
            # JSON launch record participates in task binding.
        }
    }
    if ($records.Count -ne 1) {
        throw "Expected exactly one Ceiling launch record, found $($records.Count)."
    }
    $record = $records[0]
    $launchPid = 0
    if (-not [int]::TryParse([string]$record.pid, [ref]$launchPid) -or $launchPid -le 0) {
        throw 'Ceiling launch record has no valid process id.'
    }
    if ($null -eq $record.control) {
        throw 'Ceiling launch record has no control endpoint.'
    }
    $logDirectory = [string]$record.log_dir
    if ([string]::IsNullOrWhiteSpace($logDirectory)) {
        throw 'Ceiling launch record has no log directory.'
    }
    [void](ConvertFrom-WslPath -WslPath $logDirectory)
    if (-not [string]::Equals(
        $logDirectory.TrimEnd('/'),
        $ExpectedWslLogDirectory.TrimEnd('/'),
        [StringComparison]::Ordinal
    )) {
        throw 'Ceiling launch record does not match the caller-bound log directory.'
    }
    return $record
}

function Wait-ForTaskRegistration {
    param(
        [Parameter(Mandatory)][int]$InspectPid,
        [Parameter(Mandatory)][string]$LogDirectory
    )
    $deadline = [DateTime]::UtcNow.AddMinutes(2)
    $logPrefix = (ConvertTo-WslPath -WindowsPath $LogDirectory).TrimEnd('/') + '/'
    do {
        Ensure-SupervisorWatchdog
        if (Test-StopRequested) {
            throw [OperationCanceledException]::new(
                'Supervisor stop requested during Ceiling registration.'
            )
        }
        $liveCybench = @(Get-RunningTasks | Where-Object {
            $_.task -eq 'cybench_isolated' -and
            $null -eq $_.completed_at
        })
        $matches = @($liveCybench | Where-Object {
            [int]$_.pid -eq $InspectPid -and
            [string]$_.model -eq $ExpectedModel -and
            ([string]$_.log_location).StartsWith($logPrefix, [StringComparison]::Ordinal)
        })
        if ($matches.Count -eq 1) {
            if ($liveCybench.Count -ne 1) {
                throw 'Another live Cybench task appeared during Ceiling registration.'
            }
            return $matches[0]
        }
        if ($matches.Count -gt 1) {
            throw 'More than one matching Ceiling task registered.'
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Ceiling task did not register within two minutes.'
}

function Wait-ForDetachedTaskToStop {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $liveMatches = @(Get-RunningTasks | Where-Object {
            [string]$_.task_id -eq $TaskId -and $null -eq $_.completed_at
        })
        if ($liveMatches.Count -eq 0) {
            return $true
        }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Stop-ExactDetachedTask {
    param([Parameter(Mandatory)][string]$TaskId)

    [void](Invoke-InspectJson -Arguments @(
        'ctl', 'task', 'cancel', $TaskId, '--action', 'score', '--json'
    ))
    if (Wait-ForDetachedTaskToStop -TaskId $TaskId -TimeoutSeconds 30) {
        return
    }
    [void](Invoke-InspectJson -Arguments @(
        'ctl', 'task', 'cancel', $TaskId, '--json'
    ))
    if (-not (Wait-ForDetachedTaskToStop -TaskId $TaskId -TimeoutSeconds 15)) {
        throw "Detached task rollback could not terminate exact task $TaskId."
    }
}

function Stop-DetachedLaunch {
    param(
        $LaunchRecord = $null,
        $RegisteredTask = $null,
        [Parameter(Mandatory)][string]$ExpectedWslLogDirectory,
        [Parameter(Mandatory)][string]$Reason
    )

    $launchPid = if ($null -ne $LaunchRecord) { [int]$LaunchRecord.pid } else { 0 }
    $logDirectory = $ExpectedWslLogDirectory.TrimEnd('/')
    $taskId = if ($null -ne $RegisteredTask) {
        [string]$RegisteredTask.task_id
    }
    else {
        $null
    }
    if ([string]::IsNullOrWhiteSpace($taskId)) {
        for ($attempt = 0; $attempt -lt 30; $attempt += 1) {
            try {
                $runningTasks = @(Get-RunningTasks)
            }
            catch {
                # CTL loss must not bypass the exact process witness below.
                break
            }
            $matches = @($runningTasks | Where-Object {
                $_.task -eq 'cybench_isolated' -and
                ($null -eq $LaunchRecord -or [int]$_.pid -eq $launchPid) -and
                [string]$_.model -eq $ExpectedModel -and
                ([string]$_.log_location).StartsWith(
                    $logDirectory.TrimEnd('/') + '/',
                    [StringComparison]::Ordinal
                )
            })
            if ($matches.Count -gt 1) {
                throw 'Rollback found multiple tasks for one detached launch.'
            }
            if ($matches.Count -eq 1) {
                $taskId = [string]$matches[0].task_id
                break
            }
            Start-Sleep -Seconds 1
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($taskId)) {
        try {
            Stop-ExactDetachedTask -TaskId $taskId
            Write-EventRecord -Name 'detached_launch_rolled_back' -Data @{
                task_id = $taskId
                inspect_pid = $launchPid
                reason = $Reason
                action = 'score'
            }
            return
        }
        catch {
            # Concurrent completion or CTL loss falls through to the exact
            # launch-process witness.
        }
    }

    if ($null -eq $LaunchRecord) {
        $witnessedPids = @(& wsl.exe -d Ubuntu-24.04 --cd $projectRoot -- `
            /usr/bin/timeout --signal=TERM --kill-after=2s 5s `
            bash scripts/find-cybench-launch-pids.sh $logDirectory 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw 'Ceiling rollback could not inspect the witnessed process set.'
        }
        $witnessedPids = @($witnessedPids | Where-Object { [string]$_ -match '^[1-9][0-9]*$' })
        if ($witnessedPids.Count -gt 1) {
            throw 'Ceiling rollback found multiple processes for one launch witness.'
        }
        if ($witnessedPids.Count -eq 0) {
            return
        }
        $launchPid = [int]$witnessedPids[0]
    }

    & wsl.exe -d Ubuntu-24.04 -- /bin/kill -0 $launchPid 2>$null
    if ($LASTEXITCODE -ne 0) {
        return
    }
    # Registration may fail before the task endpoint exists. Re-resolve the
    # exact argv/log-directory witness before terminating only that process.
    $termWitnesses = @(& wsl.exe -d Ubuntu-24.04 --cd $projectRoot -- `
        /usr/bin/timeout --signal=TERM --kill-after=2s 5s `
        bash scripts/find-cybench-launch-pids.sh $logDirectory 2>$null)
    $termWitnesses = @($termWitnesses | Where-Object {
        [string]$_ -match '^[1-9][0-9]*$'
    })
    if (
        $LASTEXITCODE -ne 0 -or
        $termWitnesses.Count -ne 1 -or
        [int]$termWitnesses[0] -ne $launchPid
    ) {
        throw 'Detached launch rollback lost its exact process witness before TERM.'
    }
    & wsl.exe -d Ubuntu-24.04 -- /bin/kill -TERM $launchPid 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Detached launch rollback could not terminate the recorded process.'
    }
    for ($attempt = 0; $attempt -lt 50; $attempt += 1) {
        & wsl.exe -d Ubuntu-24.04 -- /bin/kill -0 $launchPid 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-EventRecord -Name 'detached_launch_process_terminated' -Data @{
                inspect_pid = $launchPid
                reason = $Reason
            }
            return
        }
        Start-Sleep -Milliseconds 100
    }
    # Re-resolve the exact log-directory witness immediately before KILL. A
    # numeric PID alone is never authority because Linux may reuse it after
    # the TERM wait.
    $killWitnesses = @(& wsl.exe -d Ubuntu-24.04 --cd $projectRoot -- `
        /usr/bin/timeout --signal=TERM --kill-after=2s 5s `
        bash scripts/find-cybench-launch-pids.sh $logDirectory 2>$null)
    $killWitnesses = @($killWitnesses | Where-Object {
        [string]$_ -match '^[1-9][0-9]*$'
    })
    if (
        $LASTEXITCODE -ne 0 -or
        $killWitnesses.Count -ne 1 -or
        [int]$killWitnesses[0] -ne $launchPid
    ) {
        throw 'Detached launch rollback lost its exact process witness before KILL.'
    }
    & wsl.exe -d Ubuntu-24.04 -- /bin/kill -KILL $launchPid 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Detached launch rollback could not escalate the recorded process.'
    }
    for ($attempt = 0; $attempt -lt 20; $attempt += 1) {
        & wsl.exe -d Ubuntu-24.04 -- /bin/kill -0 $launchPid 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-EventRecord -Name 'detached_launch_process_terminated' -Data @{
                inspect_pid = $launchPid
                reason = $Reason
            }
            return
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'Detached launch rollback could not verify process death after KILL.'
}

function Start-CeilingStage {
    if (Test-StopRequested) {
        return 'stopped'
    }
    $liveCybench = @(Get-RunningTasks | Where-Object { $_.task -eq 'cybench_isolated' -and $null -eq $_.completed_at })
    if ($liveCybench.Count -ne 0) {
        throw 'Refusing to launch Ceiling while another Cybench task is live.'
    }

    $script:state.state = 'launching_ceiling'
    $script:state.ceiling.status = 'launching'
    Save-State
    Write-EventRecord -Name 'ceiling_launch_started'

    $ceilingRunId = (
        [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' +
        [guid]::NewGuid().ToString('N')
    )
    $expectedCeilingLogDirectory = Join-Path `
        $projectRoot "artifacts\logs\$ceilingRunId-cybench"
    $expectedCeilingWslLogDirectory = ConvertTo-WslPath `
        -WindowsPath $expectedCeilingLogDirectory
    $script:state.ceiling.launch_id = $ceilingRunId
    $script:state.ceiling.expected_log_directory = $expectedCeilingLogDirectory
    Save-State
    $launchRecord = $null
    $registered = $null
    try {
        Ensure-SupervisorWatchdog
        $launchOutput = & (Join-Path $PSScriptRoot 'run-cybench.ps1') `
            -Profile ceiling `
            -AgentPolicy ([string]$script:state.ceiling.expected_agent_policy) `
            -AgentToolchain ([string]$script:state.ceiling.expected_agent_toolchain) `
            -RunId $ceilingRunId `
            -NoViewer 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw 'Ceiling launcher returned a non-zero exit code.'
        }
        $launchRecord = Get-LaunchRecord `
            -Output @($launchOutput) `
            -ExpectedWslLogDirectory $expectedCeilingWslLogDirectory
        $ceilingLogDirectory = ConvertFrom-WslPath -WslPath ([string]$launchRecord.log_dir)
        $registered = Wait-ForTaskRegistration `
            -InspectPid ([int]$launchRecord.pid) `
            -LogDirectory $ceilingLogDirectory
    }
    catch [OperationCanceledException] {
        Stop-DetachedLaunch `
            -LaunchRecord $launchRecord `
            -RegisteredTask $registered `
            -ExpectedWslLogDirectory $expectedCeilingWslLogDirectory `
            -Reason 'supervisor_stop_requested'
        return 'stopped'
    }
    catch {
        Stop-DetachedLaunch `
            -LaunchRecord $launchRecord `
            -RegisteredTask $registered `
            -ExpectedWslLogDirectory $expectedCeilingWslLogDirectory `
            -Reason 'ceiling_registration_failed'
        throw
    }
    if (Test-StopRequested) {
        Stop-DetachedLaunch `
            -LaunchRecord $launchRecord `
            -RegisteredTask $registered `
            -ExpectedWslLogDirectory $expectedCeilingWslLogDirectory `
            -Reason 'supervisor_stop_requested'
        return 'stopped'
    }
    $script:state.ceiling.status = 'running'
    $script:state.ceiling.task_id = [string]$registered.task_id
    $script:state.ceiling.inspect_pid = [int]$registered.pid
    $script:state.ceiling.log_directory = $ceilingLogDirectory
    $script:state.ceiling.started_at_utc = Get-UtcTimestamp
    $script:state.state = 'monitoring_ceiling'
    Save-State
    Write-EventRecord -Name 'ceiling_registered' -Data @{ task_id = [string]$registered.task_id }
    return 'started'
}

function Monitor-Stage {
    param([Parameter(Mandatory)][ValidateSet('core', 'ceiling')][string]$Profile)

    $stage = $script:state.$Profile
    $missingPolls = 0
    $endpointCheckAt = [DateTime]::MinValue
    $gpuCheckAt = [DateTime]::MinValue
    $traceCheckAt = [DateTime]::MinValue
    # Carry transient issues across Core -> Ceiling so the first successful
    # poll in the new stage can explicitly recover them instead of leaving a
    # stale issue in state forever.
    $endpointFailureActive = $script:state.health.active_transient_issues.Contains(
        'endpoint_check_failed'
    )
    $gpuFailureActive = $script:state.health.active_transient_issues.Contains(
        'gpu_telemetry_failed'
    )
    $ctlFailureActive = $script:state.health.active_transient_issues.Contains(
        'ctl_poll_failed'
    )
    $samplePollFailureActive = $script:state.health.active_transient_issues.Contains(
        'sample_poll_failed'
    )
    $taskPauseActive = $false
    $technicalBlockActive = $false
    $technicalPauseDeadline = $null
    $technicalFinalizeRequested = $false
    $technicalFinalizeEscalated = $false
    $technicalFinalizeDeadline = $null
    $technicalFinalizeTimeoutReported = $false
    $integrityBlockReason = $null
    $integrityBlockIssue = $null
    $lastSampleKey = $null
    $lastCompactionCounts = @{}
    $lastCompactionStates = @{}
    $watchdogFailureActive = $false
    $missingProcessDeadline = $null
    $ctlOutageStartedAt = $null
    $samplePollOutageStartedAt = $null
    $ctlContainmentRetryAt = [DateTime]::MinValue
    $sampleContainmentRetryAt = [DateTime]::MinValue
    $script:monitoringOutageGraceSeconds = 600
    while ($true) {
        if (Test-StopRequested) {
            $script:state.state = 'supervisor_stopped'
            $script:state.desired_state = 'stopped'
            Save-State
            Write-EventRecord -Name 'supervisor_stopped' -Data @{ active_profile = $Profile }
            return 'stopped'
        }

        try {
            Ensure-SupervisorWatchdog
            if ($watchdogFailureActive) {
                $watchdogFailureActive = $false
                Write-EventRecord -Name 'supervisor_watchdog_recovered' -Data @{
                    profile = $Profile
                    watchdog_pid = [int]$script:state.watchdog_pid
                }
                if (
                    $null -ne $script:state.last_issue -and
                    [string]$script:state.last_issue.reason -eq 'supervisor_watchdog_unavailable'
                ) {
                    $script:state.last_issue = Get-LatestTransientHealthIssue
                }
            }
        }
        catch {
            if (-not $watchdogFailureActive) {
                Write-EventRecord -Name 'supervisor_watchdog_unavailable' -Data @{
                    profile = $Profile
                }
            }
            $watchdogFailureActive = $true
            Set-Blocked -Reason 'supervisor_watchdog_unavailable' -Issue (Get-SafeError $_)
            # The worker itself remains the active monitor and retries the
            # watchdog next poll; the eval is not abandoned.
        }

        if ([DateTime]::UtcNow -ge $endpointCheckAt) {
            $activeProbeStartedAt = [DateTime]::UtcNow
            $script:state.health.active_probe = [ordered]@{
                name = 'endpoint_check'
                started_at_utc = $activeProbeStartedAt.ToString('o')
                deadline_utc = $activeProbeStartedAt.AddSeconds(420).ToString('o')
            }
            Save-State
            try {
                Test-Endpoint
                $script:state.health.endpoint_last_ok_utc = Get-UtcTimestamp
                $script:state.health.consecutive_endpoint_failures = 0
                if ($endpointFailureActive) {
                    Write-EventRecord -Name 'endpoint_recovered' -Data @{ profile = $Profile }
                    $endpointFailureActive = $false
                    Clear-TransientHealthIssue -Reason 'endpoint_check_failed'
                }
            }
            catch [IO.InvalidDataException] {
                $script:state.health.consecutive_endpoint_failures = [int]$script:state.health.consecutive_endpoint_failures + 1
                if ([string]::IsNullOrWhiteSpace([string]$integrityBlockReason)) {
                    $integrityBlockReason = 'endpoint_identity_mismatch'
                    $integrityBlockIssue = Get-SafeError $_
                    $stage.integrity_block = [ordered]@{
                        reason = $integrityBlockReason
                        detail = $integrityBlockIssue
                        at_utc = Get-UtcTimestamp
                    }
                    Set-Blocked -Reason $integrityBlockReason -Issue $integrityBlockIssue
                    Write-EventRecord -Name 'endpoint_identity_mismatch' -Data @{
                        profile = $Profile
                    }
                }
            }
            catch {
                $script:state.health.consecutive_endpoint_failures = [int]$script:state.health.consecutive_endpoint_failures + 1
                Set-TransientHealthIssue -Reason 'endpoint_check_failed' -ErrorRecord $_
                if (-not $endpointFailureActive) {
                    Write-EventRecord -Name 'endpoint_unavailable' -Data @{ profile = $Profile }
                    $endpointFailureActive = $true
                }
            }
            finally {
                $script:state.health.active_probe = $null
            }
            $endpointCheckAt = [DateTime]::UtcNow.AddSeconds(60)
            Save-State
        }

        if ([DateTime]::UtcNow -ge $gpuCheckAt) {
            try {
                $script:state.health.gpu = Get-GpuTelemetry
                $script:state.health.gpu_last_ok_utc = Get-UtcTimestamp
                $script:state.health.consecutive_gpu_failures = 0
                if ($gpuFailureActive) {
                    Write-EventRecord -Name 'gpu_telemetry_recovered' -Data @{ profile = $Profile }
                    $gpuFailureActive = $false
                    Clear-TransientHealthIssue -Reason 'gpu_telemetry_failed'
                }
            }
            catch {
                $script:state.health.consecutive_gpu_failures = [int]$script:state.health.consecutive_gpu_failures + 1
                Set-TransientHealthIssue -Reason 'gpu_telemetry_failed' -ErrorRecord $_
                if (-not $gpuFailureActive) {
                    Write-EventRecord -Name 'gpu_telemetry_unavailable' -Data @{ profile = $Profile }
                    $gpuFailureActive = $true
                }
            }
            $gpuCheckAt = [DateTime]::UtcNow.AddSeconds(300)
            Save-State
        }

        try {
            $tasks = @(Get-RunningTasks)
            $script:state.health.ctl_last_ok_utc = Get-UtcTimestamp
            $script:state.health.consecutive_ctl_failures = 0
            $script:state.health.ctl_outage_started_at_utc = $null
            $ctlOutageStartedAt = $null
            if ($ctlFailureActive) {
                Write-EventRecord -Name 'inspect_control_recovered' -Data @{ profile = $Profile }
                $ctlFailureActive = $false
                Clear-TransientHealthIssue -Reason 'ctl_poll_failed'
            }
        }
        catch {
            if ($null -eq $ctlOutageStartedAt) {
                $ctlOutageStartedAt = [DateTime]::UtcNow
                $script:state.health.ctl_outage_started_at_utc = $ctlOutageStartedAt.ToString('o')
            }
            $script:state.health.consecutive_ctl_failures = [int]$script:state.health.consecutive_ctl_failures + 1
            Set-TransientHealthIssue -Reason 'ctl_poll_failed' -ErrorRecord $_
            if (-not $ctlFailureActive) {
                Write-EventRecord -Name 'inspect_control_unavailable' -Data @{ profile = $Profile }
                $ctlFailureActive = $true
            }
            if (
                ([DateTime]::UtcNow - $ctlOutageStartedAt).TotalSeconds -ge
                    $script:monitoringOutageGraceSeconds -and
                [DateTime]::UtcNow -ge $ctlContainmentRetryAt
            ) {
                $ctlContainmentRetryAt = [DateTime]::UtcNow.AddSeconds(60)
                if (Invoke-MonitoringOutageContainment `
                    -Stage $stage `
                    -Profile $Profile `
                    -Reason 'ctl_monitoring_outage_timeout' `
                    -StartedAt $ctlOutageStartedAt
                ) {
                    return 'blocked'
                }
            }
            Save-State
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        $otherLiveCybench = @($tasks | Where-Object {
            $_.task -eq 'cybench_isolated' -and
            $null -eq $_.completed_at -and
            [string]$_.task_id -ne [string]$stage.task_id
        })
        if ($otherLiveCybench.Count -gt 0) {
            if ([string]::IsNullOrWhiteSpace([string]$integrityBlockReason)) {
                $integrityBlockReason = 'parallel_cybench_task_detected'
                $integrityBlockIssue = [ordered]@{
                    count = $otherLiveCybench.Count
                    task_ids = @($otherLiveCybench | ForEach-Object { [string]$_.task_id })
                }
                $stage.integrity_block = [ordered]@{
                    reason = $integrityBlockReason
                    detail = $integrityBlockIssue
                    at_utc = Get-UtcTimestamp
                }
                Write-EventRecord -Name 'parallel_cybench_task_detected' -Data @{
                    profile = $Profile
                    count = $otherLiveCybench.Count
                }
            }
        }

        $task = @($tasks | Where-Object { [string]$_.task_id -eq [string]$stage.task_id })
        if ($task.Count -gt 1) {
            $stage.integrity_block = [ordered]@{
                reason = 'duplicate_task_id_detected'
                detail = [ordered]@{
                    task_id = [string]$stage.task_id
                    count = $task.Count
                }
                at_utc = Get-UtcTimestamp
            }
            Set-Blocked -Reason 'duplicate_task_id_detected' -Issue @{
                task_id = [string]$stage.task_id
                count = $task.Count
            }
            try {
                [void](Invoke-InspectJson -Arguments @(
                    'ctl', 'task', 'pause', [string]$stage.task_id, '--json'
                ))
            }
            catch {
                Set-Blocked -Reason 'duplicate_task_pause_failed' -Issue (Get-SafeError $_)
            }
            try {
                Stop-DetachedLaunch `
                    -LaunchRecord $null `
                    -RegisteredTask ([pscustomobject]@{
                        task_id = [string]$stage.task_id
                    }) `
                    -ExpectedWslLogDirectory (
                        ConvertTo-WslPath -WindowsPath ([string]$stage.log_directory)
                    ) `
                    -Reason 'duplicate_task_id_detected'
                return 'blocked'
            }
            catch {
                Set-Blocked `
                    -Reason 'duplicate_task_termination_failed' `
                    -Issue (Get-SafeError $_)
            }
            Start-Sleep -Seconds $PollSeconds
            continue
        }
        if ($task.Count -eq 0) {
            $missingPolls += 1
            if ($missingPolls -lt 3) {
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            $expectedMissingWslLogDirectory = ConvertTo-WslPath `
                -WindowsPath ([string]$stage.log_directory)
            $witnessedPids = @(& wsl.exe -d Ubuntu-24.04 --cd $projectRoot -- `
                /usr/bin/timeout --signal=TERM --kill-after=2s 5s `
                bash scripts/find-cybench-launch-pids.sh `
                $expectedMissingWslLogDirectory 2>$null)
            if ($LASTEXITCODE -ne 0) {
                Set-Blocked `
                    -Reason 'task_missing_process_witness_failed' `
                    -Issue ([ordered]@{ task_id = [string]$stage.task_id })
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            $witnessedPids = @($witnessedPids | Where-Object {
                [string]$_ -match '^[1-9][0-9]*$'
            })
            if ($witnessedPids.Count -gt 1) {
                Set-Blocked `
                    -Reason 'task_missing_multiple_processes' `
                    -Issue ([ordered]@{ task_id = [string]$stage.task_id })
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            if ($witnessedPids.Count -eq 1) {
                if ($null -eq $missingProcessDeadline) {
                    $missingProcessDeadline = [DateTime]::UtcNow.AddSeconds(300)
                    Set-Blocked `
                        -Reason 'task_missing_process_still_live' `
                        -Issue ([ordered]@{
                            task_id = [string]$stage.task_id
                            inspect_pid = [int]$witnessedPids[0]
                        })
                }
                if ([DateTime]::UtcNow -ge $missingProcessDeadline) {
                    Stop-DetachedLaunch `
                        -LaunchRecord ([pscustomobject]@{
                            pid = [int]$witnessedPids[0]
                        }) `
                        -RegisteredTask $null `
                        -ExpectedWslLogDirectory $expectedMissingWslLogDirectory `
                        -Reason 'task_missing_process_timeout'
                    return 'blocked'
                }
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            break
        }

        $missingPolls = 0
        $missingProcessDeadline = $null
        $task = $task[0]
        $expectedStageWslLogPrefix = (
            ConvertTo-WslPath -WindowsPath ([string]$stage.log_directory)
        ).TrimEnd('/') + '/'
        $actualStageLogLocation = [string]$task.log_location
        $stageLogMatches = $actualStageLogLocation.StartsWith(
            $expectedStageWslLogPrefix,
            [StringComparison]::Ordinal
        )
        if (-not $stageLogMatches) {
            if ([string]::IsNullOrWhiteSpace([string]$integrityBlockReason)) {
                $integrityBlockReason = 'task_log_location_mismatch'
                $integrityBlockIssue = [ordered]@{
                    expected_prefix = $expectedStageWslLogPrefix
                    actual = $actualStageLogLocation
                }
                $stage.integrity_block = [ordered]@{
                    reason = $integrityBlockReason
                    detail = $integrityBlockIssue
                    at_utc = Get-UtcTimestamp
                }
                Set-Blocked -Reason $integrityBlockReason -Issue $integrityBlockIssue
                Write-EventRecord -Name 'task_log_location_mismatch_detected' -Data @{
                    profile = $Profile
                }
                Save-State
            }
        }
        elseif ([int]$task.pid -le 0) {
            if ([string]::IsNullOrWhiteSpace([string]$integrityBlockReason)) {
                $integrityBlockReason = 'inspect_pid_invalid'
                $integrityBlockIssue = [ordered]@{
                    actual = [int]$task.pid
                }
                $stage.integrity_block = [ordered]@{
                    reason = $integrityBlockReason
                    detail = $integrityBlockIssue
                    at_utc = Get-UtcTimestamp
                }
                Set-Blocked -Reason $integrityBlockReason -Issue $integrityBlockIssue
                Write-EventRecord -Name 'inspect_pid_invalid_detected' -Data @{
                    profile = $Profile
                }
                Save-State
            }
        }
        else {
            if ($null -eq $stage.inspect_pid) {
                $stage.inspect_pid = [int]$task.pid
            }
            elseif ([int]$stage.inspect_pid -ne [int]$task.pid) {
                $integrityBlockReason = 'inspect_pid_changed'
                $integrityBlockIssue = [ordered]@{
                    expected = [int]$stage.inspect_pid
                    actual = [int]$task.pid
                }
                $stage.integrity_block = [ordered]@{
                    reason = $integrityBlockReason
                    detail = $integrityBlockIssue
                    at_utc = Get-UtcTimestamp
                }
            }
        }
        if ($null -ne $task.completed_at) {
            break
        }
        if (
            $technicalFinalizeRequested -and
            $null -ne $technicalFinalizeDeadline -and
            [DateTime]::UtcNow -ge $technicalFinalizeDeadline
        ) {
            if (-not $technicalFinalizeEscalated) {
                $escalationError = $null
                try {
                    [void](Invoke-InspectJson -Arguments @(
                        'ctl', 'task', 'cancel', [string]$stage.task_id, '--json'
                    ))
                }
                catch {
                    # The task may have completed concurrently. Keep polling
                    # the authoritative live-task set before declaring a
                    # finalize timeout.
                    $escalationError = Get-SafeError $_
                }
                $technicalFinalizeEscalated = $true
                $technicalFinalizeDeadline = [DateTime]::UtcNow.AddSeconds(60)
                $stage.technical_finalize.escalated_at_utc = Get-UtcTimestamp
                $stage.technical_finalize.escalation_error = $escalationError
                Write-EventRecord -Name 'technical_task_finalize_escalated' -Data @{
                    profile = $Profile
                    action = 'cancel'
                    command_error = $null -ne $escalationError
                }
            }
            else {
                if (-not $technicalFinalizeTimeoutReported) {
                    $technicalFinalizeTimeoutReported = $true
                    $stage.technical_finalize.timed_out_at_utc = Get-UtcTimestamp
                    Write-EventRecord -Name 'technical_task_finalize_timeout' -Data @{
                        profile = $Profile
                        task_id = [string]$stage.task_id
                    }
                }
                $stage.technical_finalize.termination_attempts = (
                    [int]$stage.technical_finalize.termination_attempts + 1
                )
                Set-Blocked -Reason 'technical_finalize_timeout' -Issue ([ordered]@{
                    profile = $Profile
                    task_id = [string]$stage.task_id
                    score_wait_seconds = 300
                    escalation_wait_seconds = 60
                    termination_attempt = [int]$stage.technical_finalize.termination_attempts
                })
                try {
                    $terminationLaunchRecord = if (
                        $null -ne $stage.inspect_pid -and [int]$stage.inspect_pid -gt 0
                    ) {
                        [pscustomobject]@{ pid = [int]$stage.inspect_pid }
                    }
                    else {
                        $null
                    }
                    $terminationTask = [pscustomobject]@{
                        task_id = [string]$stage.task_id
                    }
                    Stop-DetachedLaunch `
                        -LaunchRecord $terminationLaunchRecord `
                        -RegisteredTask $terminationTask `
                        -ExpectedWslLogDirectory (
                            ConvertTo-WslPath -WindowsPath ([string]$stage.log_directory)
                        ) `
                        -Reason 'technical_finalize_timeout'
                    $stage.technical_finalize.last_termination_error = $null
                    Save-State
                    return 'blocked'
                }
                catch {
                    $stage.technical_finalize.last_termination_error = Get-SafeError $_
                    Set-Blocked `
                        -Reason 'technical_finalize_termination_failed' `
                        -Issue $stage.technical_finalize.last_termination_error
                    # Remain the active watcher and retry only the exact bound
                    # task/process after another bounded interval.
                    $technicalFinalizeDeadline = [DateTime]::UtcNow.AddSeconds(60)
                }
            }
        }
        if ([string]$task.model -ne $ExpectedModel) {
            if ([string]::IsNullOrWhiteSpace([string]$integrityBlockReason)) {
                $integrityBlockReason = 'unexpected_model'
                $integrityBlockIssue = [ordered]@{
                    actual = [string]$task.model
                    expected = $ExpectedModel
                }
                $stage.integrity_block = [ordered]@{
                    reason = $integrityBlockReason
                    detail = $integrityBlockIssue
                    at_utc = Get-UtcTimestamp
                }
                Write-EventRecord -Name 'unexpected_model_detected' -Data @{
                    profile = $Profile
                    actual = [string]$task.model
                }
            }
        }

        try {
            $progress = Get-SampleProgress -TaskId ([string]$stage.task_id)
            $script:state.health.sample_poll_last_ok_utc = Get-UtcTimestamp
            $script:state.health.sample_poll_outage_started_at_utc = $null
            $samplePollOutageStartedAt = $null
            if ($samplePollFailureActive) {
                Write-EventRecord -Name 'sample_poll_recovered' -Data @{ profile = $Profile }
                $samplePollFailureActive = $false
                Clear-TransientHealthIssue -Reason 'sample_poll_failed'
            }
            $runningSamples = @($progress.samples | Where-Object { $_.status -eq 'running' })
            $currentSample = @($runningSamples | Select-Object -First 1)
            $currentSampleRecord = $null
            if ($currentSample.Count -eq 1) {
                $current = $currentSample[0]
                $currentSampleKey = "$([string]$current.sample_id)::$([int]$current.epoch)"
                $idleSeconds = $null
                if ($null -ne $current.last_activity_at) {
                    $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
                    $idleSeconds = [Math]::Round(
                        [Math]::Max(0.0, $nowUnix - [double]$current.last_activity_at),
                        3
                    )
                }
                $currentSampleRecord = [ordered]@{
                    sample_id = [string]$current.sample_id
                    epoch = [int]$current.epoch
                    started_at_unix = $current.started_at
                    last_activity_at_unix = $current.last_activity_at
                    idle_seconds = $idleSeconds
                    activity = $current.activity
                    event_count = $current.events
                    cumulative_total_tokens = [int64]$current.total_tokens
                    cumulative_message_count = [int]$current.message_count
                    turn_count = [int]$current.turn_count
                }
                $priorCurrentSample = if (
                    $null -ne $script:state.progress -and
                    $null -ne $script:state.progress.current_sample
                ) {
                    $script:state.progress.current_sample
                }
                else {
                    $null
                }
                if (
                    $null -ne $priorCurrentSample -and
                    [string]$priorCurrentSample.sample_id -eq [string]$current.sample_id -and
                    [int]$priorCurrentSample.epoch -eq [int]$current.epoch -and
                    $null -ne $priorCurrentSample.PSObject.Properties['compaction']
                ) {
                    $currentSampleRecord.compaction = $priorCurrentSample.compaction
                }
                if ($currentSampleKey -ne $lastSampleKey) {
                    Write-EventRecord -Name 'sample_started' -Data @{
                        profile = $Profile
                        sample_id = [string]$current.sample_id
                        epoch = [int]$current.epoch
                        previous_sample = $lastSampleKey
                    }
                    $lastSampleKey = $currentSampleKey
                }

                if ([DateTime]::UtcNow -ge $traceCheckAt) {
                    try {
                        $compaction = Get-CompactionTelemetry `
                            -TaskId ([string]$stage.task_id) `
                            -SampleId ([string]$current.sample_id) `
                            -Epoch ([int]$current.epoch)
                        $currentSampleRecord.compaction = $compaction
                        $script:state.health.trace_last_ok_utc = Get-UtcTimestamp
                        $script:state.health.consecutive_trace_failures = 0
                        $priorCompactionCount = if ($lastCompactionCounts.ContainsKey($currentSampleKey)) {
                            [int]$lastCompactionCounts[$currentSampleKey]
                        }
                        else {
                            0
                        }
                        if ([int]$compaction.count -gt $priorCompactionCount) {
                            Write-EventRecord -Name 'compaction_observed' -Data @{
                                profile = $Profile
                                sample_id = [string]$current.sample_id
                                epoch = [int]$current.epoch
                                count = [int]$compaction.count
                                structural_continuation = [string]$compaction.structural_continuation
                                invalid_event_count = [int]$compaction.invalid_event_count
                            }
                        }
                        $compactionState = (
                            [string]$compaction.count + '::' +
                            [string]$compaction.structural_continuation + '::' +
                            [string]$compaction.invalid_event_count
                        )
                        if (
                            $lastCompactionStates.ContainsKey($currentSampleKey) -and
                            [string]$lastCompactionStates[$currentSampleKey] -ne $compactionState
                        ) {
                            Write-EventRecord -Name 'compaction_state_changed' -Data @{
                                profile = $Profile
                                sample_id = [string]$current.sample_id
                                epoch = [int]$current.epoch
                                count = [int]$compaction.count
                                structural_continuation = [string]$compaction.structural_continuation
                                invalid_event_count = [int]$compaction.invalid_event_count
                            }
                        }
                        if (
                            [int]$compaction.invalid_event_count -gt 0 -and
                            (
                                -not $lastCompactionStates.ContainsKey($currentSampleKey) -or
                                [string]$lastCompactionStates[$currentSampleKey] -ne $compactionState
                            )
                        ) {
                            Write-EventRecord -Name 'compaction_trace_anomaly_observed' -Data @{
                                profile = $Profile
                                sample_id = [string]$current.sample_id
                                epoch = [int]$current.epoch
                                invalid_event_count = [int]$compaction.invalid_event_count
                            }
                        }
                        $lastCompactionCounts[$currentSampleKey] = [int]$compaction.count
                        $lastCompactionStates[$currentSampleKey] = $compactionState
                    }
                    catch {
                        # Live transcript telemetry is best-effort and may race
                        # sample teardown. It must never pause or block the eval.
                        $script:state.health.consecutive_trace_failures = [int]$script:state.health.consecutive_trace_failures + 1
                        if ([int]$script:state.health.consecutive_trace_failures -eq 1) {
                            Write-EventRecord -Name 'trace_telemetry_unavailable' -Data @{
                                profile = $Profile
                                sample_id = [string]$current.sample_id
                            }
                        }
                    }
                    $traceCheckAt = [DateTime]::UtcNow.AddSeconds(60)
                }
            }
            elseif ($null -ne $lastSampleKey) {
                Write-EventRecord -Name 'sample_left_running_state' -Data @{
                    profile = $Profile
                    sample = $lastSampleKey
                    completed = [int]$progress.counts.completed
                    error = [int]$progress.counts.error
                    cancelled = [int]$progress.counts.cancelled
                }
                $lastSampleKey = $null
            }

            $pauseSources = @()
            if ($null -ne $task.PSObject.Properties['paused']) {
                $pauseSources = @($task.paused | Where-Object {
                    $null -ne $_ -and
                    -not [string]::IsNullOrWhiteSpace([string]$_)
                })
            }
            $processPaused = (
                $null -ne $task.PSObject.Properties['process_paused'] -and
                [bool]$task.process_paused
            )
            $taskPaused = $pauseSources.Count -gt 0 -or $processPaused
            $script:state.progress = [ordered]@{
                profile = $Profile
                counts = $progress.counts
                current_sample = $currentSampleRecord
                cumulative_total_tokens = [int64]$task.total_tokens
                cumulative_total_messages = [int]$task.total_messages
                refusals = [int]$task.refusals
                http_retries = [int]$task.http_retries
                task_pause = [ordered]@{
                    paused = $taskPaused
                    sources = $pauseSources
                    process_paused = $processPaused
                    paused_now = if ($null -ne $task.PSObject.Properties['paused_now']) {
                        @($task.paused_now | Where-Object {
                            $null -ne $_ -and
                            -not [string]::IsNullOrWhiteSpace([string]$_)
                        })
                    }
                    else { @() }
                    held = if ($null -ne $task.PSObject.Properties['held']) { [int]$task.held } else { 0 }
                    quiesced = if ($null -ne $task.PSObject.Properties['quiesced']) { [bool]$task.quiesced } else { $false }
                }
            }
            if (
                [int]$progress.counts.error -gt 0 -or
                [int]$progress.counts.cancelled -gt 0 -or
                -not [string]::IsNullOrWhiteSpace([string]$integrityBlockReason)
            ) {
                $technicalIssue = if (
                    -not [string]::IsNullOrWhiteSpace([string]$integrityBlockReason)
                ) {
                    $integrityBlockIssue
                }
                else {
                    [ordered]@{
                    error = [int]$progress.counts.error
                    cancelled = [int]$progress.counts.cancelled
                    }
                }
                $managedBlockReason = if (
                    -not [string]::IsNullOrWhiteSpace([string]$integrityBlockReason)
                ) {
                    [string]$integrityBlockReason
                }
                else {
                    'technical_sample_status'
                }
                if (-not $technicalBlockActive) {
                    $technicalBlockActive = $true
                    $technicalPauseDeadline = [DateTime]::UtcNow.AddSeconds(300)
                    $stage.technical_finalize = [ordered]@{
                        pause_grace_deadline_utc = $technicalPauseDeadline.ToString('o')
                        score_requested_at_utc = $null
                        score_requested_without_quiescence = $false
                        escalated_at_utc = $null
                        escalation_error = $null
                        termination_attempts = 0
                        last_termination_error = $null
                        timed_out_at_utc = $null
                    }
                    Set-Blocked -Reason $managedBlockReason -Issue $technicalIssue
                    Write-EventRecord -Name 'technical_sample_status_detected' -Data @{
                        profile = $Profile
                        error = [int]$progress.counts.error
                        cancelled = [int]$progress.counts.cancelled
                        reason = $managedBlockReason
                    }
                }
                if (-not $taskPaused -and -not $technicalFinalizeRequested) {
                    try {
                        [void](Invoke-InspectJson -Arguments @(
                            'ctl', 'task', 'pause', [string]$stage.task_id, '--json'
                        ))
                        Write-EventRecord -Name 'technical_task_soft_paused' -Data @{
                            profile = $Profile
                        }
                        if (
                            $null -ne $script:state.last_issue -and
                            [string]$script:state.last_issue.reason -eq 'technical_pause_failed'
                        ) {
                            Set-Blocked -Reason $managedBlockReason -Issue $technicalIssue
                        }
                    }
                    catch {
                        Set-Blocked -Reason 'technical_pause_failed' -Issue (Get-SafeError $_)
                    }
                }
                if (
                    (
                        [bool]$script:state.progress.task_pause.quiesced -or
                        (
                            $null -ne $technicalPauseDeadline -and
                            [DateTime]::UtcNow -ge $technicalPauseDeadline
                        )
                    ) -and
                    -not $technicalFinalizeRequested
                ) {
                    $technicalFinalizeRequested = $true
                    $technicalFinalizeDeadline = [DateTime]::UtcNow.AddSeconds(300)
                    $stage.technical_finalize.score_requested_at_utc = Get-UtcTimestamp
                    $stage.technical_finalize.score_requested_without_quiescence = -not [bool]$script:state.progress.task_pause.quiesced
                    try {
                        [void](Invoke-InspectJson -Arguments @(
                            'ctl', 'task', 'cancel', [string]$stage.task_id,
                            '--action', 'score', '--json'
                        ))
                        Set-Blocked -Reason $managedBlockReason -Issue $technicalIssue
                        Write-EventRecord -Name 'technical_task_finalize_requested' -Data @{
                            profile = $Profile
                            action = 'score'
                            command_error = $false
                        }
                    }
                    catch {
                        Set-Blocked -Reason 'technical_finalize_failed' -Issue (Get-SafeError $_)
                        Write-EventRecord -Name 'technical_task_finalize_requested' -Data @{
                            profile = $Profile
                            action = 'score'
                            command_error = $true
                        }
                    }
                }
            }
            if ($taskPaused) {
                if (-not $taskPauseActive) {
                    Write-EventRecord -Name 'task_pause_observed' -Data @{
                        profile = $Profile
                        sources = $pauseSources
                        process_paused = $processPaused
                        quiesced = [bool]$script:state.progress.task_pause.quiesced
                        held = [int]$script:state.progress.task_pause.held
                    }
                }
                $taskPauseActive = $true
                $script:state.state = 'attention_required'
                if (-not $technicalBlockActive) {
                    $script:state.last_issue = [ordered]@{
                        reason = 'task_paused'
                        detail = $script:state.progress.task_pause
                        at_utc = Get-UtcTimestamp
                    }
                }
            }
            elseif ($taskPauseActive) {
                $taskPauseActive = $false
                Write-EventRecord -Name 'task_pause_released' -Data @{ profile = $Profile }
                if (-not $technicalBlockActive) {
                    $script:state.state = "monitoring_$Profile"
                    if ($null -ne $script:state.last_issue -and $script:state.last_issue.reason -eq 'task_paused') {
                        $script:state.last_issue = Get-LatestTransientHealthIssue
                    }
                }
            }
        }
        catch {
            if ($null -eq $samplePollOutageStartedAt) {
                $samplePollOutageStartedAt = [DateTime]::UtcNow
                $script:state.health.sample_poll_outage_started_at_utc = (
                    $samplePollOutageStartedAt.ToString('o')
                )
            }
            Set-TransientHealthIssue -Reason 'sample_poll_failed' -ErrorRecord $_
            if (-not $samplePollFailureActive) {
                Write-EventRecord -Name 'sample_poll_unavailable' -Data @{ profile = $Profile }
                $samplePollFailureActive = $true
            }
            if (
                ([DateTime]::UtcNow - $samplePollOutageStartedAt).TotalSeconds -ge
                    $script:monitoringOutageGraceSeconds -and
                [DateTime]::UtcNow -ge $sampleContainmentRetryAt
            ) {
                $sampleContainmentRetryAt = [DateTime]::UtcNow.AddSeconds(60)
                if (Invoke-MonitoringOutageContainment `
                    -Stage $stage `
                    -Profile $Profile `
                    -Reason 'sample_monitoring_outage_timeout' `
                    -StartedAt $samplePollOutageStartedAt
                ) {
                    return 'blocked'
                }
            }
        }
        Save-State
        if (Test-StopRequested) {
            continue
        }
        Start-Sleep -Seconds $PollSeconds
    }

    $stage.status = 'verifying'
    $script:state.state = "verifying_$Profile"
    Save-State
    $finalHealthDeadline = [DateTime]::UtcNow.AddSeconds($FinalHealthTimeoutSeconds)
    $finalHealthAttempt = 0
    $lastFinalHealthState = $null
    $lastFinalHealthError = $null
    while ($true) {
        try {
            Ensure-SupervisorWatchdog
        }
        catch {
            Set-Blocked -Reason 'supervisor_watchdog_unavailable' -Issue (Get-SafeError $_)
            # Final-health remains active and retries the watchdog on the next
            # bounded iteration.
        }
        if (Test-StopRequested) {
            $script:state.state = 'supervisor_stopped'
            $script:state.desired_state = 'stopped'
            Save-State
            Write-EventRecord -Name 'supervisor_stopped' -Data @{ active_profile = $Profile }
            return 'stopped'
        }
        if ([DateTime]::UtcNow -ge $finalHealthDeadline) {
            Set-Blocked -Reason "$Profile`_final_health_timeout" -Issue ([ordered]@{
                timeout_seconds = $FinalHealthTimeoutSeconds
                attempts = $finalHealthAttempt
                last_state = $lastFinalHealthState
                last_error = $lastFinalHealthError
            })
            return 'blocked'
        }
        $finalHealthAttempt += 1
        try {
            $remainingFinalHealthSeconds = [Math]::Max(
                1,
                [Math]::Ceiling(($finalHealthDeadline - [DateTime]::UtcNow).TotalSeconds)
            )
            $probeTimeoutSeconds = [Math]::Min(120, $remainingFinalHealthSeconds)
            $health = Invoke-FinalHealth -LogDirectory ([string]$stage.log_directory) -Profile $Profile -ExpectedSamples $expectedCounts[$Profile] -TaskId ([string]$stage.task_id) -ExpectedCompactionThresholdTokens ([int]$stage.expected_compaction_threshold_tokens) -ExpectedAgentPolicy ([string]$stage.expected_agent_policy) -ExpectedAgentToolchain ([string]$stage.expected_agent_toolchain) -ExpectedToolOutputMaxBytes ([int]$stage.expected_tool_output_max_bytes) -ProbeTimeoutSeconds ([int]$probeTimeoutSeconds)
            $lastFinalHealthState = [string]$health.result.state
            $lastFinalHealthError = $null
            $stage.health = $health.result
            Save-State
            if (
                [string]$health.result.state -eq 'complete' -and
                [int]$health.exit_code -ne 0
            ) {
                Set-Blocked -Reason "$Profile`_final_health_exit_mismatch" -Issue ([ordered]@{
                    state = [string]$health.result.state
                    exit_code = [int]$health.exit_code
                })
                return 'blocked'
            }
            if ([string]$health.result.state -eq 'complete') {
                if ($null -ne $stage.integrity_block) {
                    Set-Blocked `
                        -Reason ([string]$stage.integrity_block.reason) `
                        -Issue $stage.integrity_block.detail
                    return 'blocked'
                }
                $healthLogPath = [string]$health.result.log_file
                if ($healthLogPath.StartsWith('/mnt/', [StringComparison]::Ordinal)) {
                    $healthLogPath = ConvertFrom-WslPath -WslPath $healthLogPath
                }
                $evalFile = Get-Item -LiteralPath $healthLogPath
                $stage.status = 'complete'
                $stage.completed_at_utc = Get-UtcTimestamp
                $stage.log_sha256 = (Get-FileHash -LiteralPath $evalFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                $stage.health = $health.result
                Save-State
                Write-EventRecord -Name "$Profile`_verified" -Data @{ samples = $expectedCounts[$Profile] }
                return 'complete'
            }
            if ([string]$health.result.state -notin @('running', 'unreadable')) {
                Set-Blocked -Reason "$Profile`_final_health_failed" -Issue $health.result
                return 'blocked'
            }
        }
        catch {
            $lastFinalHealthState = 'unreadable'
            $lastFinalHealthError = Get-SafeError $_
            $script:state.last_issue = [ordered]@{
                reason = "$Profile`_final_health_retry"
                detail = $lastFinalHealthError
                at_utc = Get-UtcTimestamp
            }
            Save-State
        }
        if ([DateTime]::UtcNow -ge $finalHealthDeadline) {
            Set-Blocked -Reason "$Profile`_final_health_timeout" -Issue ([ordered]@{
                timeout_seconds = $FinalHealthTimeoutSeconds
                attempts = $finalHealthAttempt
                last_state = $lastFinalHealthState
                last_error = $lastFinalHealthError
            })
            return 'blocked'
        }
        Start-Sleep -Seconds 10
    }
}

$lockStream = $null
$sleepGuardSet = $false
$script:state = $null
try {
    $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    [void][QwenEvalPowerState]::SetThreadExecutionState([uint32]2147483649)
    $sleepGuardSet = $true

    $resolvedCoreLogDirectory = (Resolve-Path -LiteralPath $CoreLogDirectory).Path
    $coreLaunchId = Get-LaunchIdFromLogDirectory -LogDirectory $resolvedCoreLogDirectory
    $script:state = [ordered]@{
        schema_version = 1
        plan_id = [guid]::NewGuid().ToString()
        sequence = 0
        state = 'monitoring_core'
        desired_state = 'running'
        worker_pid = $PID
        startup_nonce = $StartupNonce
        watchdog_pid = $null
        watchdog_nonce = $null
        started_at_utc = Get-UtcTimestamp
        updated_at_utc = Get-UtcTimestamp
        expected_model = $ExpectedModel
        expected_model_context_tokens = $ExpectedModelContextTokens
        expected_model_api_timeout_policy = $ExpectedModelApiTimeoutPolicy
        expected_model_api_client_timeout_seconds = $ExpectedModelApiClientTimeoutSeconds
        poll_seconds = $PollSeconds
        final_health_timeout_seconds = $FinalHealthTimeoutSeconds
        event_log = $eventsPath
        previous_event_archive = $null
        core = [ordered]@{
            status = 'running'
            task_id = $CoreTaskId
            launch_id = $coreLaunchId
            expected_log_directory = $resolvedCoreLogDirectory
            expected_compaction_threshold_tokens = $CoreExpectedCompactionThresholdTokens
            expected_agent_policy = $CoreExpectedAgentPolicy
            expected_agent_toolchain = $CoreExpectedAgentToolchain
            expected_tool_output_max_bytes = $CoreExpectedToolOutputMaxBytes
            inspect_pid = $CoreInspectPid
            log_directory = $resolvedCoreLogDirectory
            started_at_utc = Get-UtcTimestamp
            completed_at_utc = $null
            log_sha256 = $null
            health = $null
            integrity_block = $null
            technical_finalize = $null
        }
        ceiling = [ordered]@{
            status = 'pending'
            task_id = $null
            launch_id = $null
            expected_log_directory = $null
            expected_compaction_threshold_tokens = $CeilingExpectedCompactionThresholdTokens
            expected_agent_policy = $CeilingExpectedAgentPolicy
            expected_agent_toolchain = $CeilingExpectedAgentToolchain
            expected_tool_output_max_bytes = $CeilingExpectedToolOutputMaxBytes
            inspect_pid = $null
            log_directory = $null
            started_at_utc = $null
            completed_at_utc = $null
            log_sha256 = $null
            health = $null
            integrity_block = $null
            technical_finalize = $null
        }
        progress = $null
        health = [ordered]@{
            ctl_last_ok_utc = $null
            ctl_outage_started_at_utc = $null
            endpoint_last_ok_utc = $null
            gpu_last_ok_utc = $null
            gpu = $null
            trace_last_ok_utc = $null
            sample_poll_last_ok_utc = $null
            sample_poll_outage_started_at_utc = $null
            consecutive_ctl_failures = 0
            consecutive_endpoint_failures = 0
            consecutive_gpu_failures = 0
            consecutive_trace_failures = 0
            active_transient_issues = [ordered]@{}
            active_probe = $null
        }
        last_issue = $null
    }
    $script:state.previous_event_archive = Archive-ExistingEventLog
    Save-State
    Ensure-SupervisorWatchdog
    Write-EventRecord -Name 'supervisor_started' -Data @{
        core_task_id = $CoreTaskId
        core_compaction_threshold_tokens = $CoreExpectedCompactionThresholdTokens
        ceiling_compaction_threshold_tokens = $CeilingExpectedCompactionThresholdTokens
        final_health_timeout_seconds = $FinalHealthTimeoutSeconds
        model_api_timeout_policy = $ExpectedModelApiTimeoutPolicy
        model_api_client_timeout_seconds = $ExpectedModelApiClientTimeoutSeconds
        core_agent_policy = $CoreExpectedAgentPolicy
        ceiling_agent_policy = $CeilingExpectedAgentPolicy
        core_agent_toolchain = $CoreExpectedAgentToolchain
        ceiling_agent_toolchain = $CeilingExpectedAgentToolchain
    }

    $coreResult = Monitor-Stage -Profile core
    if ($coreResult -ne 'complete') {
        exit 0
    }

    if (Test-StopRequested) {
        $script:state.state = 'supervisor_stopped'
        $script:state.desired_state = 'stopped'
        Save-State
        Write-EventRecord -Name 'supervisor_stopped' -Data @{
            active_profile = 'between_core_and_ceiling'
        }
        exit 0
    }

    try {
        $ceilingLaunchResult = Start-CeilingStage
        if ($ceilingLaunchResult -eq 'stopped') {
            $script:state.state = 'supervisor_stopped'
            $script:state.desired_state = 'stopped'
            Save-State
            Write-EventRecord -Name 'supervisor_stopped' -Data @{
                active_profile = 'ceiling_launch'
            }
            exit 0
        }
    }
    catch {
        Set-Blocked -Reason 'ceiling_launch_failed' -Issue (Get-SafeError $_)
        exit 1
    }

    $ceilingResult = Monitor-Stage -Profile ceiling
    if ($ceilingResult -eq 'complete') {
        $script:state.state = 'complete'
        $script:state.desired_state = 'complete'
        $script:state.progress = $null
        Save-State
        Write-EventRecord -Name 'supervisor_complete'
    }
}
catch [System.IO.IOException] {
    if ($null -eq $lockStream) {
        Write-Error 'Another Cybench supervisor already holds the worker lock.'
        exit 3
    }
    if ($null -ne $script:state) {
        Set-Blocked -Reason 'supervisor_io_exception' -Issue (Get-SafeError $_)
    }
    throw
}
catch {
    if ($null -ne $script:state) {
        Set-Blocked -Reason 'supervisor_exception' -Issue (Get-SafeError $_)
    }
    throw
}
finally {
    if ($sleepGuardSet) {
        [void][QwenEvalPowerState]::SetThreadExecutionState([uint32]2147483648)
    }
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
}

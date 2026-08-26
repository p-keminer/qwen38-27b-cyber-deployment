param(
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$WorkerPid,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$StartupNonce,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$WatchdogNonce,
    [ValidateRange(5, 300)][int]$PollSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$stateDirectory = Join-Path $projectRoot '.runpod\cybench-supervisor'
$statePath = Join-Path $stateDirectory 'state.json'
$watchdogStatePath = Join-Path $stateDirectory 'watchdog.json'
$stopRequestPath = Join-Path $stateDirectory 'stop.request.json'
$workerPath = Join-Path $PSScriptRoot 'cybench-supervisor-worker.ps1'
$inspectBinary = '/home/qwen-eval/.local/share/qwen-eval/.venv/bin/inspect'
[IO.Directory]::CreateDirectory($stateDirectory) | Out-Null

function Get-UtcTimestamp {
    return [DateTime]::UtcNow.ToString('o')
}

function Get-SafeError {
    param([Parameter(Mandatory)]$ErrorRecord)
    return [ordered]@{
        exception_type = $ErrorRecord.Exception.GetType().FullName
        provider_message_omitted = $true
    }
}

function Save-WatchdogState {
    param([Parameter(Mandatory)]$State)
    $State.updated_at_utc = Get-UtcTimestamp
    $temporaryPath = "$watchdogStatePath.$PID.tmp"
    [IO.File]::WriteAllText(
        $temporaryPath,
        ($State | ConvertTo-Json -Depth 10),
        (New-Object System.Text.UTF8Encoding($false))
    )
    Move-Item -LiteralPath $temporaryPath -Destination $watchdogStatePath -Force
}

function Get-SupervisorState {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'Supervisor state is missing.'
    }
    return Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
}

function Save-SupervisorStoppedState {
    param([Parameter(Mandatory)]$SupervisorState)

    # Re-read immediately before the write so a stale watchdog can never
    # acknowledge a stop for a replacement plan.
    $latest = Get-SupervisorState
    if (
        -not [string]::Equals(
            [string]$latest.plan_id,
            [string]$SupervisorState.plan_id,
            [StringComparison]::Ordinal
        ) -or
        -not [string]::Equals(
            [string]$latest.startup_nonce,
            $StartupNonce,
            [StringComparison]::Ordinal
        ) -or
        -not [string]::Equals(
            [string]$latest.watchdog_nonce,
            $WatchdogNonce,
            [StringComparison]::Ordinal
        )
    ) {
        throw 'Supervisor plan changed before watchdog stop acknowledgement.'
    }
    $latest.state = 'supervisor_stopped'
    $latest.desired_state = 'stopped'
    $latest.updated_at_utc = Get-UtcTimestamp
    $temporaryPath = "$statePath.watchdog-$PID.tmp"
    [IO.File]::WriteAllText(
        $temporaryPath,
        ($latest | ConvertTo-Json -Depth 20),
        (New-Object System.Text.UTF8Encoding($false))
    )
    Move-Item -LiteralPath $temporaryPath -Destination $statePath -Force
}

function Get-ValidActiveProbeDeadline {
    param([Parameter(Mandatory)]$SupervisorState)

    if (
        $null -eq $SupervisorState.PSObject.Properties['health'] -or
        $null -eq $SupervisorState.health -or
        $null -eq $SupervisorState.health.PSObject.Properties['active_probe'] -or
        $null -eq $SupervisorState.health.active_probe
    ) {
        return $null
    }
    try {
        $probe = $SupervisorState.health.active_probe
        if ([string]$probe.name -ne 'endpoint_check') {
            return $null
        }
        $startedAt = [DateTime]::Parse(
            [string]$probe.started_at_utc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        $deadline = [DateTime]::Parse(
            [string]$probe.deadline_utc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        $now = [DateTime]::UtcNow
        if (
            $startedAt -gt $now.AddSeconds(5) -or
            $deadline -le $startedAt -or
            ($deadline - $startedAt).TotalSeconds -gt 420
        ) {
            return $null
        }
        return $deadline
    }
    catch {
        return $null
    }
}

function Test-BoundStopRequest {
    param([Parameter(Mandatory)]$SupervisorState)
    if (-not (Test-Path -LiteralPath $stopRequestPath -PathType Leaf)) {
        return $false
    }
    try {
        $request = Get-Content -LiteralPath $stopRequestPath -Raw -Encoding utf8 | ConvertFrom-Json
        return (
            [string]$request.action -eq 'stop_supervisor_only' -and
            [string]::Equals(
                [string]$request.plan_id,
                [string]$SupervisorState.plan_id,
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

function Test-ExactWorker {
    $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $WorkerPid" -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return $false
    }
    $commandLine = [string]$process.CommandLine
    return (
        $commandLine.IndexOf($workerPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $commandLine.Contains($StartupNonce)
    )
}

function Invoke-InspectJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & wsl.exe -d Ubuntu-24.04 -- /usr/bin/timeout `
        --signal=TERM --kill-after=5s 25s $inspectBinary @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Inspect control command failed with exit code $LASTEXITCODE."
    }
    $text = (@($output) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'Inspect control command returned no JSON.'
    }
    return $text | ConvertFrom-Json
}

function Test-ExactTaskLive {
    param([Parameter(Mandatory)][string]$TaskId)
    $payload = Invoke-InspectJson -Arguments @('ctl', 'task', 'list', '--json')
    return @($payload.tasks | Where-Object {
        [string]$_.task_id -eq $TaskId -and $null -eq $_.completed_at
    }).Count -eq 1
}

function Stop-ExactInspectTask {
    param([Parameter(Mandatory)][string]$TaskId)
    try {
        [void](Invoke-InspectJson -Arguments @(
            'ctl', 'task', 'cancel', $TaskId, '--action', 'score', '--json'
        ))
    }
    catch {
        if (-not (Test-ExactTaskLive -TaskId $TaskId)) {
            return
        }
        throw
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-ExactTaskLive -TaskId $TaskId)) {
            return
        }
        Start-Sleep -Seconds 1
    }
    [void](Invoke-InspectJson -Arguments @(
        'ctl', 'task', 'cancel', $TaskId, '--json'
    ))
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-ExactTaskLive -TaskId $TaskId)) {
            return
        }
        Start-Sleep -Seconds 1
    }
    throw 'Watchdog could not finalize the exact launch-stage task.'
}

function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$WindowsPath)
    $fullPath = [IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -notmatch '^(?<drive>[A-Za-z]):\\(?<tail>.*)$') {
        throw 'Cannot bind the watchdog to a non-drive log path.'
    }
    return '/mnt/' + $Matches.drive.ToLowerInvariant() + '/' + $Matches.tail.Replace('\', '/')
}

function Get-WitnessedLaunchPids {
    param([Parameter(Mandatory)][string]$ExpectedWslLogDirectory)
    $output = @(& wsl.exe -d Ubuntu-24.04 --cd $projectRoot -- `
        /usr/bin/timeout --signal=TERM --kill-after=2s 5s `
        bash scripts/find-cybench-launch-pids.sh `
        $ExpectedWslLogDirectory.TrimEnd('/') 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw 'Watchdog could not inspect the exact launch-process witness.'
    }
    return @($output | Where-Object { [string]$_ -match '^[1-9][0-9]*$' } | ForEach-Object { [int]$_ })
}

function Get-WitnessedRunnerPids {
    param([Parameter(Mandatory)][string]$RunId)
    $output = @(& wsl.exe -d Ubuntu-24.04 --cd $projectRoot -- `
        /usr/bin/timeout --signal=TERM --kill-after=2s 5s `
        bash scripts/find-cybench-runner-pids.sh $RunId 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw 'Watchdog could not inspect the exact runner-process witness.'
    }
    return @($output | Where-Object { [string]$_ -match '^[1-9][0-9]*$' } | ForEach-Object { [int]$_ })
}

function Stop-ExactWitnessedProcess {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][ValidateSet('launch', 'runner')][string]$WitnessKind,
        [Parameter(Mandatory)][string]$WitnessValue
    )
    $currentPids = if ($WitnessKind -eq 'launch') {
        @(Get-WitnessedLaunchPids -ExpectedWslLogDirectory $WitnessValue)
    }
    else {
        @(Get-WitnessedRunnerPids -RunId $WitnessValue)
    }
    if ($currentPids.Count -ne 1 -or [int]$currentPids[0] -ne $ProcessId) {
        throw 'Exact process witness changed before termination.'
    }
    & wsl.exe -d Ubuntu-24.04 -- /bin/kill -TERM $ProcessId 2>$null
    if ($LASTEXITCODE -ne 0) {
        # Concurrent process exit is a successful containment outcome.
        & wsl.exe -d Ubuntu-24.04 -- /bin/kill -0 $ProcessId 2>$null
        if ($LASTEXITCODE -ne 0) {
            return
        }
        throw 'Watchdog could not terminate the exact witnessed process.'
    }
    for ($attempt = 0; $attempt -lt 50; $attempt += 1) {
        & wsl.exe -d Ubuntu-24.04 -- /bin/kill -0 $ProcessId 2>$null
        if ($LASTEXITCODE -ne 0) {
            return
        }
        Start-Sleep -Milliseconds 100
    }
    $currentPids = if ($WitnessKind -eq 'launch') {
        @(Get-WitnessedLaunchPids -ExpectedWslLogDirectory $WitnessValue)
    }
    else {
        @(Get-WitnessedRunnerPids -RunId $WitnessValue)
    }
    if ($currentPids.Count -ne 1 -or [int]$currentPids[0] -ne $ProcessId) {
        throw 'Exact process witness changed before kill escalation.'
    }
    & wsl.exe -d Ubuntu-24.04 -- /bin/kill -KILL $ProcessId 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Watchdog could not escalate the exact witnessed process.'
    }
    for ($attempt = 0; $attempt -lt 50; $attempt += 1) {
        & wsl.exe -d Ubuntu-24.04 -- /bin/kill -0 $ProcessId 2>$null
        if ($LASTEXITCODE -ne 0) {
            return
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'Exact witnessed process remained alive after kill escalation.'
}

function Get-ActiveStage {
    param([Parameter(Mandatory)]$SupervisorState)
    $profile = if (
        [string]$SupervisorState.ceiling.status -in @('launching', 'running', 'verifying')
    ) {
        'ceiling'
    }
    elseif (
        $null -ne $SupervisorState.progress -and
        [string]$SupervisorState.progress.profile -in @('core', 'ceiling')
    ) {
        [string]$SupervisorState.progress.profile
    }
    else {
        'core'
    }
    return [pscustomobject]@{
        profile = $profile
        stage = $SupervisorState.$profile
    }
}

$watchdogState = [ordered]@{
    schema_version = 1
    state = 'watching'
    watchdog_pid = $PID
    worker_pid = $WorkerPid
    startup_nonce = $StartupNonce
    watchdog_nonce = $WatchdogNonce
    started_at_utc = Get-UtcTimestamp
    updated_at_utc = Get-UtcTimestamp
    worker_exit_detected_at_utc = $null
    active_profile = $null
    task_id = $null
    task_live = $null
    soft_pause_requested = $false
    task_quiesced = $null
    launch_process_pid = $null
    last_issue = $null
}
Save-WatchdogState -State $watchdogState

$workerFailureLatched = $false
$workerFailureDeadline = $null
$missingLivePolls = 0
$launchStopContainment = $false
while ($true) {
    try {
        $supervisorState = Get-SupervisorState
    }
    catch {
        $watchdogState.state = 'attention_required'
        $watchdogState.last_issue = [ordered]@{
            reason = 'supervisor_state_unreadable'
            detail = Get-SafeError $_
            at_utc = Get-UtcTimestamp
        }
        Save-WatchdogState -State $watchdogState
        Start-Sleep -Seconds $PollSeconds
        continue
    }

    if (-not [string]::Equals(
        [string]$supervisorState.startup_nonce,
        $StartupNonce,
        [StringComparison]::Ordinal
    )) {
        $watchdogState.state = 'attention_required'
        $watchdogState.last_issue = [ordered]@{
            reason = 'startup_nonce_mismatch'
            at_utc = Get-UtcTimestamp
        }
        Save-WatchdogState -State $watchdogState
        exit 2
    }
    if (-not [string]::Equals(
        [string]$supervisorState.watchdog_nonce,
        $WatchdogNonce,
        [StringComparison]::Ordinal
    )) {
        $watchdogState.state = 'replaced'
        Save-WatchdogState -State $watchdogState
        exit 0
    }

    if (
        [string]$supervisorState.desired_state -in @('stopped', 'complete') -or
        [string]$supervisorState.state -in @('supervisor_stopped', 'complete')
    ) {
        $watchdogState.state = 'clean_exit'
        Save-WatchdogState -State $watchdogState
        exit 0
    }

    $workerHeartbeatFresh = $false
    try {
        $workerUpdatedAt = [DateTime]::Parse(
            [string]$supervisorState.updated_at_utc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        $workerMaximumAgeSeconds = if (
            [string]$supervisorState.ceiling.status -eq 'launching'
        ) {
            900
        }
        else {
            [Math]::Max(300, $PollSeconds * 4)
        }
        $activeProbeDeadline = Get-ValidActiveProbeDeadline -SupervisorState $supervisorState
        $workerHeartbeatFresh = if (
            $null -ne $activeProbeDeadline -and
            [DateTime]::UtcNow -le $activeProbeDeadline
        ) {
            $true
        }
        else {
            (
                ([DateTime]::UtcNow - $workerUpdatedAt).TotalSeconds -le
                $workerMaximumAgeSeconds
            )
        }
    }
    catch {
        $workerHeartbeatFresh = $false
    }

    if ((Test-ExactWorker) -and $workerHeartbeatFresh) {
        $watchdogState.state = 'watching'
        $watchdogState.last_issue = $null
        Save-WatchdogState -State $watchdogState
        Start-Sleep -Seconds $PollSeconds
        continue
    }

    if (-not $workerFailureLatched) {
        $workerFailureLatched = $true
        $watchdogState.worker_exit_detected_at_utc = Get-UtcTimestamp
        $workerFailureDeadline = [DateTime]::UtcNow.AddSeconds(300)
    }
    $watchdogState.state = 'attention_required'
    $active = Get-ActiveStage -SupervisorState $supervisorState
    $stage = $active.stage
    $watchdogState.active_profile = $active.profile
    $watchdogState.last_issue = [ordered]@{
        reason = if (Test-ExactWorker) {
            'supervisor_worker_heartbeat_stale'
        }
        else {
            'supervisor_worker_exited'
        }
        at_utc = Get-UtcTimestamp
    }
    $taskId = [string]$stage.task_id
    $stageStatus = [string]$stage.status
    $launchId = [string]$stage.launch_id
    $stopDuringLaunch = (
        $stageStatus -eq 'launching' -and
        (Test-BoundStopRequest -SupervisorState $supervisorState)
    )
    if ($stopDuringLaunch) {
        $launchStopContainment = $true
    }
    if (
        $stageStatus -ne 'launching' -and
        (Test-BoundStopRequest -SupervisorState $supervisorState)
    ) {
        try {
            Save-SupervisorStoppedState -SupervisorState $supervisorState
            $watchdogState.state = 'stopped'
            $watchdogState.last_issue = $null
            Save-WatchdogState -State $watchdogState
            exit 0
        }
        catch {
            $watchdogState.state = 'attention_required'
            $watchdogState.last_issue = [ordered]@{
                reason = 'supervisor_stop_acknowledgement_failed'
                detail = Get-SafeError $_
                at_utc = Get-UtcTimestamp
            }
            Save-WatchdogState -State $watchdogState
            exit 2
        }
    }
    if ($stopDuringLaunch) {
        $workerFailureDeadline = [DateTime]::UtcNow
    }
    $expectedLogDirectory = [string]$stage.expected_log_directory
    $expectedWslLogDirectory = if ([string]::IsNullOrWhiteSpace($expectedLogDirectory)) {
        $null
    }
    else {
        ConvertTo-WslPath -WindowsPath $expectedLogDirectory
    }

    try {
        $ctlError = $null
        $liveCybench = @()
        try {
            $payload = Invoke-InspectJson -Arguments @('ctl', 'task', 'list', '--json')
            $liveCybench = @($payload.tasks | Where-Object {
                $_.task -eq 'cybench_isolated' -and $null -eq $_.completed_at
            })
        }
        catch {
            # CTL loss must never bypass exact process-witness containment.
            $ctlError = Get-SafeError $_
        }
        if ([string]::IsNullOrWhiteSpace($taskId) -and -not [string]::IsNullOrWhiteSpace($expectedLogDirectory)) {
            $wslPrefix = $expectedWslLogDirectory.TrimEnd('/') + '/'
            $matches = @($liveCybench | Where-Object {
                [string]$_.model -eq [string]$supervisorState.expected_model -and
                ([string]$_.log_location).StartsWith($wslPrefix, [StringComparison]::Ordinal)
            })
            if ($matches.Count -gt 1) {
                throw 'Watchdog found multiple tasks for the exact launch witness.'
            }
            if ($matches.Count -eq 1) {
                $taskId = [string]$matches[0].task_id
            }
        }

        $expectedInspectPid = if (
            $null -ne $stage.PSObject.Properties['inspect_pid'] -and
            [int]$stage.inspect_pid -gt 0
        ) {
            [int]$stage.inspect_pid
        }
        else {
            0
        }
        $matches = @($liveCybench | Where-Object {
            [string]$_.task_id -eq $taskId -and
            [string]$_.model -eq [string]$supervisorState.expected_model -and
            ($expectedInspectPid -le 0 -or [int]$_.pid -eq $expectedInspectPid) -and
            (
                [string]::IsNullOrWhiteSpace($expectedWslLogDirectory) -or
                ([string]$_.log_location).StartsWith(
                    $expectedWslLogDirectory.TrimEnd('/') + '/',
                    [StringComparison]::Ordinal
                )
            )
        })
        if ($matches.Count -gt 1) {
            throw 'Watchdog found a duplicate task identifier.'
        }
        $watchdogState.task_id = if ([string]::IsNullOrWhiteSpace($taskId)) { $null } else { $taskId }
        $watchdogState.task_live = $matches.Count -eq 1
        if ($matches.Count -eq 1) {
            $missingLivePolls = 0
            $task = $matches[0]
            if ($stopDuringLaunch) {
                try {
                    Stop-ExactInspectTask -TaskId $taskId
                }
                catch {
                    $fallbackPids = @(Get-WitnessedLaunchPids `
                        -ExpectedWslLogDirectory $expectedWslLogDirectory)
                    if ($fallbackPids.Count -ne 1) {
                        throw
                    }
                    Stop-ExactWitnessedProcess `
                        -ProcessId ([int]$fallbackPids[0]) `
                        -WitnessKind launch `
                        -WitnessValue $expectedWslLogDirectory
                }
                Save-SupervisorStoppedState -SupervisorState $supervisorState
                $watchdogState.state = 'stopped'
                $watchdogState.last_issue = [ordered]@{
                    reason = 'launch_stage_contained_after_worker_exit'
                    at_utc = Get-UtcTimestamp
                }
                Save-WatchdogState -State $watchdogState
                exit 0
            }
            if (-not $watchdogState.soft_pause_requested) {
                if (Test-BoundStopRequest -SupervisorState $supervisorState) {
                    if ($stageStatus -eq 'launching') {
                        try {
                            Stop-ExactInspectTask -TaskId $taskId
                        }
                        catch {
                            $fallbackPids = @(Get-WitnessedLaunchPids `
                                -ExpectedWslLogDirectory $expectedWslLogDirectory)
                            if ($fallbackPids.Count -ne 1) {
                                throw
                            }
                            Stop-ExactWitnessedProcess `
                                -ProcessId ([int]$fallbackPids[0]) `
                                -WitnessKind launch `
                                -WitnessValue $expectedWslLogDirectory
                        }
                        $watchdogState.last_issue = [ordered]@{
                            reason = 'launch_stage_contained_after_worker_exit'
                            at_utc = Get-UtcTimestamp
                        }
                    }
                    Save-SupervisorStoppedState -SupervisorState $supervisorState
                    $watchdogState.state = 'stopped'
                    Save-WatchdogState -State $watchdogState
                    exit 0
                }
                [void](Invoke-InspectJson -Arguments @(
                    'ctl', 'task', 'pause', $taskId, '--json'
                ))
                $watchdogState.soft_pause_requested = $true
            }
            $watchdogState.task_quiesced = if ($null -ne $task.PSObject.Properties['quiesced']) {
                [bool]$task.quiesced
            }
            else {
                $null
            }
            $watchdogState.last_issue = [ordered]@{
                reason = 'supervisor_worker_exited_task_soft_paused'
                at_utc = Get-UtcTimestamp
            }
            Save-WatchdogState -State $watchdogState
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        $missingLivePolls += 1
        $witnessedPids = if ([string]::IsNullOrWhiteSpace($expectedWslLogDirectory)) {
            @()
        }
        else {
            @(Get-WitnessedLaunchPids -ExpectedWslLogDirectory $expectedWslLogDirectory)
        }
        if ($witnessedPids.Count -gt 1) {
            throw 'Watchdog found multiple processes for one exact launch witness.'
        }
        $runnerPids = if (
            $stageStatus -eq 'launching' -and
            -not [string]::IsNullOrWhiteSpace($launchId)
        ) {
            @(Get-WitnessedRunnerPids -RunId $launchId)
        }
        else {
            @()
        }
        if ($runnerPids.Count -gt 1) {
            throw 'Watchdog found multiple runners for one exact launch witness.'
        }
        if ($witnessedPids.Count -eq 1) {
            $watchdogState.launch_process_pid = [int]$witnessedPids[0]
            if ([DateTime]::UtcNow -lt $workerFailureDeadline) {
                $watchdogState.last_issue = [ordered]@{
                    reason = 'supervisor_worker_exited_waiting_for_task_registration'
                    at_utc = Get-UtcTimestamp
                }
                Save-WatchdogState -State $watchdogState
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            if (
                $stageStatus -ne 'launching' -and
                (Test-BoundStopRequest -SupervisorState $supervisorState)
            ) {
                Save-SupervisorStoppedState -SupervisorState $supervisorState
                $watchdogState.state = 'stopped'
                Save-WatchdogState -State $watchdogState
                exit 0
            }
            Stop-ExactWitnessedProcess `
                -ProcessId ([int]$witnessedPids[0]) `
                -WitnessKind launch `
                -WitnessValue $expectedWslLogDirectory
            $watchdogState.last_issue = [ordered]@{
                reason = 'supervisor_worker_exited_unregistered_process_stopped'
                at_utc = Get-UtcTimestamp
            }
            Save-WatchdogState -State $watchdogState
            $missingLivePolls = 0
            Start-Sleep -Seconds $PollSeconds
            continue
        }
        if ($stageStatus -eq 'launching' -and [DateTime]::UtcNow -lt $workerFailureDeadline) {
            $watchdogState.launch_process_pid = if ($runnerPids.Count -eq 1) {
                [int]$runnerPids[0]
            }
            else {
                $null
            }
            $watchdogState.last_issue = [ordered]@{
                reason = 'supervisor_worker_exited_waiting_for_launcher_or_registration'
                runner_observed = $runnerPids.Count -eq 1
                at_utc = Get-UtcTimestamp
            }
            Save-WatchdogState -State $watchdogState
            Start-Sleep -Seconds $PollSeconds
            continue
        }
        if ($runnerPids.Count -eq 1) {
            if (
                $stageStatus -ne 'launching' -and
                (Test-BoundStopRequest -SupervisorState $supervisorState)
            ) {
                Save-SupervisorStoppedState -SupervisorState $supervisorState
                $watchdogState.state = 'stopped'
                Save-WatchdogState -State $watchdogState
                exit 0
            }
            Stop-ExactWitnessedProcess `
                -ProcessId ([int]$runnerPids[0]) `
                -WitnessKind runner `
                -WitnessValue $launchId
            $watchdogState.launch_process_pid = [int]$runnerPids[0]
            $watchdogState.last_issue = [ordered]@{
                reason = 'supervisor_worker_exited_runner_stopped'
                at_utc = Get-UtcTimestamp
            }
            Save-WatchdogState -State $watchdogState
            $missingLivePolls = 0
            Start-Sleep -Seconds $PollSeconds
            continue
        }
        if ($null -ne $ctlError -and [DateTime]::UtcNow -lt $workerFailureDeadline) {
            $watchdogState.last_issue = [ordered]@{
                reason = 'supervisor_worker_exit_ctl_unavailable'
                detail = $ctlError
                at_utc = Get-UtcTimestamp
            }
            Save-WatchdogState -State $watchdogState
            Start-Sleep -Seconds $PollSeconds
            continue
        }
        if ($missingLivePolls -lt 3) {
            $watchdogState.last_issue = [ordered]@{
                reason = 'supervisor_worker_exited_task_temporarily_missing'
                missing_polls = $missingLivePolls
                at_utc = Get-UtcTimestamp
            }
            Save-WatchdogState -State $watchdogState
            Start-Sleep -Seconds $PollSeconds
            continue
        }
        if ($launchStopContainment) {
            Save-SupervisorStoppedState -SupervisorState $supervisorState
            $watchdogState.state = 'stopped'
            $watchdogState.task_quiesced = $null
            $watchdogState.last_issue = [ordered]@{
                reason = 'launch_stage_contained_after_worker_exit'
                at_utc = Get-UtcTimestamp
            }
            Save-WatchdogState -State $watchdogState
            exit 0
        }
        $watchdogState.task_quiesced = $null
        $watchdogState.last_issue = [ordered]@{
            reason = 'supervisor_worker_exited_no_live_bound_task'
            at_utc = Get-UtcTimestamp
        }
        Save-WatchdogState -State $watchdogState
        exit 1
    }
    catch {
        $watchdogState.last_issue = [ordered]@{
            reason = 'supervisor_worker_exit_containment_failed'
            detail = Get-SafeError $_
            at_utc = Get-UtcTimestamp
        }
        Save-WatchdogState -State $watchdogState
        Start-Sleep -Seconds $PollSeconds
    }
}

param(
    [ValidateSet('neutral-v1', 'baseline-v1', 'efficient-v2')]
    [string]$AgentPolicy = 'neutral-v1',
    [ValidateSet('upstream-static-v1')]
    [string]$AgentToolchain = 'upstream-static-v1',
    [switch]$NoViewer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RunPod.Common.psm1') -Force

$projectRoot = Split-Path -Parent $PSScriptRoot
$inspect = '/home/qwen-eval/.local/share/qwen-eval/.venv/bin/inspect'
$expectedModel = 'openai-api/llamacpp/qwen3.8-27b-uncensored-q6'
$supervisorWorkerPath = Join-Path $PSScriptRoot 'cybench-supervisor-worker.ps1'
$supervisorWatchdogPath = Join-Path $PSScriptRoot 'cybench-supervisor-watchdog.ps1'
$launchStateDirectory = Join-Path $projectRoot '.runpod\cybench-program'
$launchLockPath = Join-Path $launchStateDirectory 'launch.lock'
$supervisorStatePath = Join-Path $projectRoot '.runpod\cybench-supervisor\state.json'
[IO.Directory]::CreateDirectory($launchStateDirectory) | Out-Null

function Invoke-BoundedInspectJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & wsl.exe -d Ubuntu-24.04 -- /usr/bin/timeout `
        --signal=TERM --kill-after=5s 25s $inspect @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Inspect control command failed with exit code $LASTEXITCODE."
    }
    $text = (@($output) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'Inspect control command returned no JSON.'
    }
    return ($text | ConvertFrom-Json)
}

function Get-LiveCybenchTasks {
    $payload = Invoke-BoundedInspectJson -Arguments @('ctl', 'task', 'list', '--json')
    return @($payload.tasks | Where-Object {
        $_.task -eq 'cybench_isolated' -and
        $null -eq $_.completed_at
    })
}

function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$WindowsPath)
    $fullPath = [IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -notmatch '^(?<drive>[A-Za-z]):\\(?<tail>.*)$') {
        throw "Cannot convert path to WSL: $fullPath"
    }
    return '/mnt/' + $Matches.drive.ToLowerInvariant() + '/' + $Matches.tail.Replace('\', '/')
}

function Wait-ForTaskToLeaveLiveSet {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $stillLive = @(Get-LiveCybenchTasks | Where-Object {
            [string]$_.task_id -eq $TaskId
        })
        if ($stillLive.Count -eq 0) {
            return $true
        }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Stop-ExactInspectTask {
    param([Parameter(Mandatory)][string]$TaskId)

    [void](Invoke-BoundedInspectJson -Arguments @(
        'ctl', 'task', 'cancel', $TaskId, '--action', 'score', '--json'
    ))
    if (Wait-ForTaskToLeaveLiveSet -TaskId $TaskId -TimeoutSeconds 30) {
        return
    }
    # Inspect documents plain cancel as the escalation for a task stuck while
    # finishing a prior score/error cancellation.
    [void](Invoke-BoundedInspectJson -Arguments @(
        'ctl', 'task', 'cancel', $TaskId, '--json'
    ))
    if (-not (Wait-ForTaskToLeaveLiveSet -TaskId $TaskId -TimeoutSeconds 15)) {
        throw "Core rollback could not terminate exact task $TaskId."
    }
}

function Stop-DetachedCoreLaunch {
    param(
        $LaunchRecord,
        $RegisteredTask,
        [Parameter(Mandatory)][string]$ExpectedWslLogDirectory,
        [Parameter(Mandatory)][bool]$LaunchAttempted
    )

    if (-not $LaunchAttempted) {
        return
    }
    $taskId = if ($null -ne $RegisteredTask) {
        [string]$RegisteredTask.task_id
    }
    else {
        $null
    }
    $launchPid = if ($null -ne $LaunchRecord) { [int]$LaunchRecord.pid } else { 0 }
    $logDirectory = $ExpectedWslLogDirectory.TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($taskId)) {
        for ($attempt = 0; $attempt -lt 30; $attempt += 1) {
            try {
                $liveTasks = @(Get-LiveCybenchTasks)
            }
            catch {
                # CTL loss must not bypass the exact process witness below.
                break
            }
            $matches = @($liveTasks | Where-Object {
                ($null -eq $LaunchRecord -or [int]$_.pid -eq $launchPid) -and
                [string]$_.model -eq $expectedModel -and
                ([string]$_.log_location).StartsWith(
                    $logDirectory + '/', [StringComparison]::Ordinal
                )
            })
            if ($matches.Count -gt 1) {
                throw 'Core rollback found multiple candidate tasks.'
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
            Stop-ExactInspectTask -TaskId $taskId
            return
        }
        catch {
            # Concurrent completion or CTL loss falls through to the exact
            # PID/log-directory witness.
        }
    }
    if ($null -eq $LaunchRecord) {
        $witnessedPids = @(& wsl.exe -d Ubuntu-24.04 --cd $projectRoot -- `
            /usr/bin/timeout --signal=TERM --kill-after=2s 5s `
            bash scripts/find-cybench-launch-pids.sh $logDirectory 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw 'Core rollback could not inspect the witnessed process set.'
        }
        $witnessedPids = @($witnessedPids | Where-Object { [string]$_ -match '^[1-9][0-9]*$' })
        if ($witnessedPids.Count -gt 1) {
            throw 'Core rollback found multiple processes for one launch witness.'
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
        throw 'Core rollback lost its exact process witness before TERM.'
    }
    & wsl.exe -d Ubuntu-24.04 -- /bin/kill -TERM $launchPid 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Core rollback could not terminate the recorded detached process.'
    }
    for ($attempt = 0; $attempt -lt 50; $attempt += 1) {
        & wsl.exe -d Ubuntu-24.04 -- /bin/kill -0 $launchPid 2>$null
        if ($LASTEXITCODE -ne 0) {
            return
        }
        Start-Sleep -Milliseconds 100
    }
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
        throw 'Core rollback lost its exact process witness before KILL.'
    }
    & wsl.exe -d Ubuntu-24.04 -- /bin/kill -KILL $launchPid 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Core rollback could not escalate termination of the recorded process.'
    }
    for ($attempt = 0; $attempt -lt 20; $attempt += 1) {
        & wsl.exe -d Ubuntu-24.04 -- /bin/kill -0 $launchPid 2>$null
        if ($LASTEXITCODE -ne 0) {
            return
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'Core rollback could not verify process death after KILL.'
}

function Get-LiveCybenchSupervisorProcesses {
    $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    return @($processes | Where-Object {
        [string]$_.Name -in @('powershell.exe', 'pwsh.exe') -and
        (
            ([string]$_.CommandLine).IndexOf(
                $supervisorWorkerPath,
                [StringComparison]::OrdinalIgnoreCase
            ) -ge 0 -or
            ([string]$_.CommandLine).IndexOf(
                $supervisorWatchdogPath,
                [StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )
    })
}

function ConvertFrom-WslPath {
    param([Parameter(Mandatory)][string]$WslPath)
    if ($WslPath -notmatch '^/mnt/(?<drive>[a-zA-Z])/(?<tail>.*)$') {
        throw "Unexpected WSL path: $WslPath"
    }
    return $Matches.drive.ToUpperInvariant() + ':\' + $Matches.tail.Replace('/', '\')
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
            $eventProperty = $parsed.PSObject.Properties['event']
            if ($null -ne $eventProperty -and [string]$eventProperty.Value -eq 'launch') {
                $records += $parsed
            }
        }
        catch {
            # Human-readable launcher output may contain braces. Only a valid
            # JSON launch record participates in task binding.
        }
    }
    if ($records.Count -ne 1) {
        throw "Expected exactly one Inspect launch record, found $($records.Count)."
    }

    $record = $records[0]
    $launchPid = 0
    if (-not [int]::TryParse([string]$record.pid, [ref]$launchPid) -or $launchPid -le 0) {
        throw 'Inspect launch record has no valid process id.'
    }
    if ($null -eq $record.control) {
        throw 'Inspect launch record has no control endpoint.'
    }
    $logDirectory = [string]$record.log_dir
    if ([string]::IsNullOrWhiteSpace($logDirectory)) {
        throw 'Inspect launch record has no log directory.'
    }
    # Validate the path before the detached task is accepted.
    [void](ConvertFrom-WslPath -WslPath $logDirectory)
    if (-not [string]::Equals(
        $logDirectory.TrimEnd('/'),
        $ExpectedWslLogDirectory.TrimEnd('/'),
        [StringComparison]::Ordinal
    )) {
        throw 'Inspect launch record does not match the caller-bound log directory.'
    }
    return $record
}

function Wait-ForExactTaskRegistration {
    param(
        [Parameter(Mandatory)][int]$InspectPid,
        [Parameter(Mandatory)][string]$WslLogDirectory
    )

    $logPrefix = $WslLogDirectory.TrimEnd('/') + '/'
    $deadline = [DateTime]::UtcNow.AddMinutes(2)
    do {
        $liveTasks = @(Get-LiveCybenchTasks)
        $matches = @($liveTasks | Where-Object {
            [int]$_.pid -eq $InspectPid -and
            [string]$_.model -eq $expectedModel -and
            ([string]$_.log_location).StartsWith(
                $logPrefix,
                [StringComparison]::Ordinal
            )
        })
        if ($matches.Count -gt 1) {
            throw 'More than one task matches the Inspect launch record.'
        }
        if ($liveTasks.Count -ne $matches.Count) {
            throw 'Another live Cybench task appeared during program launch.'
        }
        if ($matches.Count -eq 1) {
            return $matches[0]
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The Core task from the Inspect launch record did not register within two minutes.'
}

$launchLock = $null
$launchAttempted = $false
$launchRecord = $null
$task = $null
$supervisorStarted = $false
$coreRunId = ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N'))
$expectedLogDirectory = Join-Path $projectRoot "artifacts\logs\$coreRunId-cybench"
$expectedWslLogDirectory = ConvertTo-WslPath -WindowsPath $expectedLogDirectory
try {
    try {
        $launchLock = [IO.File]::Open(
            $launchLockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    }
    catch [System.IO.IOException] {
        throw 'Another Cybench program launch is already in progress.'
    }

    $existingWorkers = @(Get-LiveCybenchSupervisorProcesses)
    if ($existingWorkers.Count -ne 0) {
        $workerPids = @($existingWorkers | ForEach-Object { [string]$_.ProcessId }) -join ', '
        throw (
            'A Cybench supervisor worker or watchdog is already running; refusing ' +
            "to launch an unmanaged Core task (PID(s): $workerPids)."
        )
    }

    if (Test-Path -LiteralPath $supervisorStatePath -PathType Leaf) {
        try {
            $existingSupervisorState = Get-Content `
                -LiteralPath $supervisorStatePath `
                -Raw `
                -Encoding utf8 | ConvertFrom-Json
        }
        catch {
            throw 'Existing supervisor state is unreadable; refusing a new Core launch.'
        }
        $existingPlanIsTerminal = (
            (
                [string]$existingSupervisorState.desired_state -eq 'stopped' -and
                [string]$existingSupervisorState.state -eq 'supervisor_stopped'
            ) -or
            (
                [string]$existingSupervisorState.desired_state -eq 'complete' -and
                [string]$existingSupervisorState.state -eq 'complete'
            )
        )
        if (-not $existingPlanIsTerminal) {
            throw 'An unfinished supervisor plan exists; refusing a new Core launch.'
        }
    }

    if (@(Get-LiveCybenchTasks).Count -ne 0) {
        throw 'A Cybench task is already live; refusing to start a second program.'
    }

    $session = Get-RunPodSession
    $expectedManifestModel = Get-RunPodModel -Model 'uncensored-q6'
    if (
        [string]$session.ActiveModel -ne 'uncensored-q6' -or
        [string]$session.ActiveAlias -ne [string]$expectedManifestModel.alias -or
        [int]$expectedManifestModel.context_size -ne 262144
    ) {
        throw (
            'The active RunPod session is not bound to the pinned Q6/262144 ' +
            'measurement configuration.'
        )
    }

    $launchAttempted = $true
    $launchOutput = @(& (Join-Path $PSScriptRoot 'run-cybench.ps1') `
        -Profile core `
        -AgentPolicy $AgentPolicy `
        -AgentToolchain $AgentToolchain `
        -RunId $coreRunId `
        -NoViewer:$NoViewer 2>&1)
    $launchRecord = Get-LaunchRecord `
        -Output $launchOutput `
        -ExpectedWslLogDirectory $expectedWslLogDirectory
    $launchPid = [int]$launchRecord.pid
    $wslLogDirectory = ([string]$launchRecord.log_dir).TrimEnd('/')
    $task = Wait-ForExactTaskRegistration `
        -InspectPid $launchPid `
        -WslLogDirectory $wslLogDirectory
    $logDirectory = ConvertFrom-WslPath -WslPath $wslLogDirectory

    & (Join-Path $PSScriptRoot 'start-cybench-supervisor.ps1') `
        -CoreTaskId ([string]$task.task_id) `
        -CoreLogDirectory $logDirectory `
        -FinalHealthTimeoutSeconds 900 `
        -ExpectedModelApiTimeoutPolicy phase-limit-owned-v1 `
        -ExpectedModelApiClientTimeoutSeconds 7500 `
        -CoreExpectedCompactionThresholdTokens 160000 `
        -CeilingExpectedCompactionThresholdTokens 160000 `
        -CoreExpectedAgentPolicy $AgentPolicy `
        -CeilingExpectedAgentPolicy $AgentPolicy `
        -CoreExpectedAgentToolchain $AgentToolchain `
        -CeilingExpectedAgentToolchain $AgentToolchain `
        -CoreExpectedToolOutputMaxBytes 16384 `
        -CeilingExpectedToolOutputMaxBytes 16384
    $supervisorStarted = $true

    Write-Host "Cybench program ready: Core -> Ceiling, policy=$AgentPolicy, toolchain=$AgentToolchain"
    Write-Host "Core task: $($task.task_id) (Inspect PID $launchPid)"
    Write-Host "Project: $projectRoot"
}
catch {
    $launchFailure = $_
    if ($launchAttempted -and -not $supervisorStarted) {
        try {
            Stop-DetachedCoreLaunch `
                -LaunchRecord $launchRecord `
                -RegisteredTask $task `
                -ExpectedWslLogDirectory $expectedWslLogDirectory `
                -LaunchAttempted $true
        }
        catch {
            throw (
                "Cybench program launch failed and rollback also failed. " +
                "Launch error: $($launchFailure.Exception.GetType().Name). " +
                "Rollback error: $($_.Exception.Message)"
            )
        }
    }
    throw $launchFailure
}
finally {
    if ($null -ne $launchLock) {
        $launchLock.Dispose()
    }
}

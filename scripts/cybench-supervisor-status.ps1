Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$statePath = Join-Path (Split-Path -Parent $PSScriptRoot) '.runpod\cybench-supervisor\state.json'
$watchdogStatePath = Join-Path (Split-Path -Parent $PSScriptRoot) '.runpod\cybench-supervisor\watchdog.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw 'No Cybench supervisor state exists.'
}
$state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
$pollSeconds = [int]$state.poll_seconds
if ($pollSeconds -le 0) {
    throw 'Supervisor state has an invalid poll_seconds value.'
}
$workerHeartbeatMaximumAgeSeconds = if (
    [string]$state.ceiling.status -eq 'launching'
) {
    900
}
else {
    [Math]::Max(300, $pollSeconds * 4)
}
$watchdogHeartbeatMaximumAgeSeconds = [Math]::Max(180, $pollSeconds * 4)

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

$process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $([int]$state.worker_pid)" -ErrorAction SilentlyContinue
$workerRunning = (
    $null -ne $process -and
    ([string]$process.CommandLine).Contains('cybench-supervisor-worker.ps1') -and
    -not [string]::IsNullOrWhiteSpace([string]$state.startup_nonce) -and
    ([string]$process.CommandLine).Contains([string]$state.startup_nonce)
)
$workerHeartbeatFresh = $false
try {
    $workerUpdatedAt = [DateTime]::Parse(
        [string]$state.updated_at_utc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()
    $activeProbeDeadline = Get-ValidActiveProbeDeadline -SupervisorState $state
    $workerHeartbeatFresh = if (
        $null -ne $activeProbeDeadline -and
        [DateTime]::UtcNow -le $activeProbeDeadline
    ) {
        $true
    }
    else {
        (
            ([DateTime]::UtcNow - $workerUpdatedAt).TotalSeconds -le
            $workerHeartbeatMaximumAgeSeconds
        )
    }
}
catch {
    $workerHeartbeatFresh = $false
}
Write-Host "Supervisor state: $($state.state)"
Write-Host "Worker running: $($workerRunning.ToString().ToLowerInvariant()) (PID $($state.worker_pid))"
$watchdogHealthy = $false
if (Test-Path -LiteralPath $watchdogStatePath -PathType Leaf) {
    $watchdogState = Get-Content -LiteralPath $watchdogStatePath -Raw -Encoding utf8 | ConvertFrom-Json
    $watchdogProcess = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $([int]$watchdogState.watchdog_pid)" -ErrorAction SilentlyContinue
    $watchdogRunning = (
        $null -ne $watchdogProcess -and
        ([string]$watchdogProcess.CommandLine).Contains('cybench-supervisor-watchdog.ps1') -and
        ([string]$watchdogProcess.CommandLine).Contains([string]$state.startup_nonce) -and
        ([string]$watchdogProcess.CommandLine).Contains([string]$state.watchdog_nonce) -and
        [int]$watchdogState.worker_pid -eq [int]$state.worker_pid -and
        [string]::Equals(
            [string]$watchdogState.watchdog_nonce,
            [string]$state.watchdog_nonce,
            [StringComparison]::Ordinal
        )
    )
    $watchdogHeartbeatFresh = $false
    try {
        $watchdogUpdatedAt = [DateTime]::Parse(
            [string]$watchdogState.updated_at_utc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        $watchdogHeartbeatFresh = (
            ([DateTime]::UtcNow - $watchdogUpdatedAt).TotalSeconds -le
            $watchdogHeartbeatMaximumAgeSeconds
        )
    }
    catch {
        $watchdogHeartbeatFresh = $false
    }
    $watchdogHealthy = $watchdogRunning -and $watchdogHeartbeatFresh
    Write-Host (
        "Watchdog state/running: $($watchdogState.state)/" +
        "$($watchdogRunning.ToString().ToLowerInvariant()) (PID $($watchdogState.watchdog_pid))"
    )
    if ($null -ne $watchdogState.last_issue) {
        Write-Host "Watchdog issue: $($watchdogState.last_issue.reason)"
    }
}
Write-Host "Expected model: $($state.expected_model)"
if ($null -ne $state.progress) {
    Write-Host "Profile: $($state.progress.profile)"
    $currentProperty = $state.progress.PSObject.Properties['current_sample']
    $current = if ($null -ne $currentProperty) { $currentProperty.Value } else { $null }
    if ($null -eq $current -or ($current -is [array] -and $current.Count -eq 0)) {
        Write-Host 'Current sample: none'
    }
    elseif ($null -eq $current.PSObject.Properties['sample_id']) {
        # Compatibility with state files written before current_sample became a
        # structured record. Do not reinterpret this legacy value as live usage.
        Write-Host "Current sample (legacy): $(@($current) -join ', ')"
    }
    else {
        Write-Host "Current sample: $($current.sample_id) (epoch $($current.epoch))"
        Write-Host "Activity: $($current.activity); idle seconds: $($current.idle_seconds)"
        if (
            $null -ne $current.PSObject.Properties['compaction'] -and
            $null -ne $current.compaction
        ) {
            Write-Host (
                "Compactions: $($current.compaction.count); " +
                "continuation: $($current.compaction.structural_continuation)"
            )
        }
    }
    Write-Host "Counts: $($state.progress.counts | ConvertTo-Json -Compress)"
    $cumulativeTokens = if ($null -ne $state.progress.PSObject.Properties['cumulative_total_tokens']) {
        $state.progress.cumulative_total_tokens
    }
    elseif ($null -ne $state.progress.PSObject.Properties['total_tokens']) {
        $state.progress.total_tokens
    }
    else { $null }
    $cumulativeMessages = if ($null -ne $state.progress.PSObject.Properties['cumulative_total_messages']) {
        $state.progress.cumulative_total_messages
    }
    elseif ($null -ne $state.progress.PSObject.Properties['total_messages']) {
        $state.progress.total_messages
    }
    else { $null }
    Write-Host (
        "Cumulative tokens/messages: " +
        "$cumulativeTokens/$cumulativeMessages"
    )
    if ($null -ne $state.progress.PSObject.Properties['task_pause']) {
        Write-Host "Task pause: $($state.progress.task_pause | ConvertTo-Json -Compress)"
    }
}
if (
    $null -ne $state.PSObject.Properties['health'] -and
    $null -ne $state.health -and
    $null -ne $state.health.PSObject.Properties['gpu'] -and
    $null -ne $state.health.gpu
) {
    Write-Host "GPU: $($state.health.gpu | ConvertTo-Json -Compress)"
}
if (
    $null -ne $state.PSObject.Properties['health'] -and
    $null -ne $state.health -and
    $null -ne $state.health.PSObject.Properties['active_transient_issues'] -and
    $null -ne $state.health.active_transient_issues
) {
    Write-Host (
        "Active transient issues: " +
        ($state.health.active_transient_issues | ConvertTo-Json -Compress -Depth 5)
    )
}
if ($null -ne $state.last_issue) {
    Write-Host "Last issue: $($state.last_issue.reason)"
}
$state | ConvertTo-Json -Depth 10
if (
    [string]$state.desired_state -eq 'running' -and
    (-not $workerRunning -or -not $workerHeartbeatFresh -or -not $watchdogHealthy)
) {
    throw 'Active supervisor liveness or heartbeat binding is invalid.'
}

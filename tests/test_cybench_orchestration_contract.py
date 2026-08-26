from __future__ import annotations

import unittest
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class CybenchOrchestrationContractTests(unittest.TestCase):
    def test_supervisor_startup_binding_uses_fresh_nonce(self) -> None:
        starter = source("scripts/start-cybench-supervisor.ps1")
        worker = source("scripts/cybench-supervisor-worker.ps1")

        self.assertIn("$startupNonce = [guid]::NewGuid().ToString('N')", starter)
        self.assertIn("'-StartupNonce', $startupNonce", starter)
        self.assertIn("Get-StateValue -State $state -Path 'startup_nonce'", starter)
        self.assertIn("[string]$StartupNonce", worker)
        self.assertIn("startup_nonce = $StartupNonce", worker)

    def test_technical_finalize_has_bounded_plain_cancel_escalation(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")

        self.assertIn("$technicalFinalizeDeadline = [DateTime]::UtcNow.AddSeconds(300)", worker)
        self.assertIn("$technicalFinalizeDeadline = [DateTime]::UtcNow.AddSeconds(60)", worker)
        self.assertIn("$technicalPauseDeadline = [DateTime]::UtcNow.AddSeconds(300)", worker)
        self.assertIn("score_requested_without_quiescence", worker)
        self.assertIn("'technical_task_finalize_escalated'", worker)
        self.assertIn("'technical_finalize_timeout'", worker)
        self.assertIn("'technical_task_finalize_timeout'", worker)
        self.assertIn("-Reason 'technical_finalize_timeout'", worker)
        self.assertIn("-Reason 'technical_finalize_termination_failed'", worker)

    def test_worker_and_watchdog_supervise_each_other_fail_closed(self) -> None:
        starter = source("scripts/start-cybench-supervisor.ps1")
        worker = source("scripts/cybench-supervisor-worker.ps1")
        watchdog = source("scripts/cybench-supervisor-watchdog.ps1")
        status = source("scripts/cybench-supervisor-status.ps1")

        self.assertIn("Ensure-SupervisorWatchdog", worker)
        self.assertIn("watchdog_pid = $null", worker)
        self.assertIn("watchdog_nonce = $null", worker)
        self.assertIn("'-WatchdogNonce', $newWatchdogNonce", worker)
        self.assertIn("'supervisor_watchdog_unavailable'", worker)
        self.assertIn("$commandLine.Contains($StartupNonce)", worker)
        self.assertIn("[string]$supervisorState.startup_nonce", watchdog)
        self.assertIn("[string]$WatchdogNonce", watchdog)
        self.assertIn("Test-ExactWorker", watchdog)
        self.assertIn("'ctl', 'task', 'pause', $taskId, '--json'", watchdog)
        self.assertIn("--kill-after=5s 25s", watchdog)
        self.assertIn("supervisor_worker_exited_task_soft_paused", watchdog)
        self.assertIn("Get-WitnessedLaunchPids", watchdog)
        self.assertIn("find-cybench-launch-pids.sh", watchdog)
        self.assertIn("$missingLivePolls -lt 3", watchdog)
        self.assertIn("$workerFailureDeadline = [DateTime]::UtcNow.AddSeconds(300)", watchdog)
        self.assertIn("supervisor_worker_exited_waiting_for_task_registration", watchdog)
        self.assertIn("find-cybench-runner-pids.sh", watchdog)
        self.assertIn("supervisor_worker_exited_waiting_for_launcher_or_registration", watchdog)
        self.assertIn("Stop-ExactWitnessedProcess", watchdog)
        active_stage = watchdog.split("function Get-ActiveStage", 1)[1].split(
            "$watchdogState =", 1
        )[0]
        self.assertLess(
            active_stage.index("$SupervisorState.ceiling.status"),
            active_stage.index("$SupervisorState.progress"),
        )
        self.assertIn("watchdog_pid", starter)
        self.assertIn("watchdogState.startup_nonce", worker)
        self.assertIn("Watchdog state/running", status)

    def test_program_serializes_launch_and_binds_the_exact_launch_record(self) -> None:
        program = source("scripts/start-cybench-program.ps1")
        wrapper = source("scripts/run-cybench.ps1")
        runner = source("scripts/run-cybench.sh")

        self.assertIn("[IO.FileShare]::None", program)
        self.assertIn("Another Cybench program launch is already in progress", program)
        self.assertIn("$launchOutput = @(&", program)
        self.assertIn("-ExpectedWslLogDirectory $expectedWslLogDirectory", program)
        self.assertIn("-InspectPid $launchPid", program)
        self.assertIn("-WslLogDirectory $wslLogDirectory", program)
        self.assertIn("[int]$_.pid -eq $InspectPid", program)
        self.assertIn("([string]$_.log_location).StartsWith(", program)
        self.assertIn("function Stop-DetachedCoreLaunch", program)
        self.assertIn("'ctl', 'task', 'cancel'", program)
        self.assertIn("'--action', 'score'", program)
        self.assertIn("$termWitnesses", program)
        self.assertIn("find-cybench-launch-pids.sh", program)
        self.assertIn("$supervisorStarted = $true", program)
        self.assertIn("-RunId $coreRunId", program)
        self.assertIn("-ExpectedWslLogDirectory $expectedWslLogDirectory", program)
        self.assertIn("[string]$RunId", wrapper)
        self.assertIn("--run-id", runner)
        self.assertIn("orchestration_launch_id=${run_id}", runner)
        self.assertIn("Refusing an existing Cybench launch directory", runner)

    def test_startup_control_reads_are_bounded(self) -> None:
        program = source("scripts/start-cybench-program.ps1")
        starter = source("scripts/start-cybench-supervisor.ps1")

        for contract in (program, starter):
            self.assertIn("/usr/bin/timeout", contract)
            self.assertIn("--kill-after=5s", contract)
            self.assertIn("25s", contract)

    def test_endpoint_and_session_are_bound_to_the_q6_measurement(self) -> None:
        program = source("scripts/start-cybench-program.ps1")
        common = source("scripts/RunPod.Common.psm1")
        worker = source("scripts/cybench-supervisor-worker.ps1")

        self.assertIn("Get-RunPodSession", program)
        self.assertIn("Get-RunPodModel -Model 'uncensored-q6'", program)
        self.assertIn("$session.ActiveModel -ne 'uncensored-q6'", program)
        self.assertIn("$modelIds.Count -ne 1", common)
        self.assertIn("$Session.ActiveAlias", common)
        self.assertIn("$Props.default_generation_settings.n_ctx", common)
        self.assertIn("$Props.model_ftype", common)
        self.assertIn("$Props.model_path", common)
        self.assertIn("local endpoint does not match the pinned model", common)
        self.assertIn("catch [IO.InvalidDataException]", worker)
        self.assertIn("endpoint_identity_mismatch", worker)
        self.assertIn("$stage.integrity_block", worker)

    def test_stop_request_is_cleared_before_not_inside_new_worker(self) -> None:
        starter = source("scripts/start-cybench-supervisor.ps1")
        worker = source("scripts/cybench-supervisor-worker.ps1")
        watchdog = source("scripts/cybench-supervisor-watchdog.ps1")
        stopper = source("scripts/stop-cybench-supervisor.ps1")

        self.assertIn("Remove-Item -LiteralPath $stopRequestPath", starter)
        self.assertNotIn("Remove-Item -LiteralPath $stopRequestPath", worker)
        self.assertIn("plan_id = [string]$state.plan_id", stopper)
        self.assertIn("startup_nonce = [string]$state.startup_nonce", stopper)
        self.assertIn("request_id = [guid]::NewGuid().ToString('N')", stopper)
        self.assertIn("Supervisor plan changed while the stop request", stopper)
        self.assertIn("function Test-StopRequested", worker)
        self.assertIn("function Test-BoundStopRequest", watchdog)

    def test_supervisor_startup_failure_stops_only_the_spawned_worker(self) -> None:
        starter = source("scripts/start-cybench-supervisor.ps1")

        self.assertIn("$workerBound = $false", starter)
        self.assertIn("if (-not $workerBound -and -not $process.HasExited)", starter)
        self.assertIn("Stop-Process -Id $process.Id -Force", starter)
        self.assertIn("$process.WaitForExit(5000)", starter)

    def test_ceiling_launch_is_bound_to_one_valid_record_and_task(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")
        launch = worker.split("function Get-LaunchRecord", 1)[1].split(
            "function Wait-ForTaskRegistration", 1
        )[0]
        registration = worker.split("function Wait-ForTaskRegistration", 1)[1].split(
            "function Start-CeilingStage", 1
        )[0]

        self.assertIn("Expected exactly one Ceiling launch record", launch)
        self.assertIn("[int]::TryParse", launch)
        self.assertIn("$record.control", launch)
        self.assertIn("ConvertFrom-WslPath", launch)
        self.assertIn("$_.task -eq 'cybench_isolated'", registration)
        self.assertIn("$null -eq $_.completed_at", registration)
        self.assertIn("$logPrefix", registration)
        self.assertIn("Another live Cybench task appeared", registration)
        self.assertIn("Supervisor stop requested during Ceiling registration", registration)

    def test_ceiling_launch_rolls_back_and_honors_stop_races(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")
        rollback = worker.split("function Wait-ForDetachedTaskToStop", 1)[1].split(
            "function Start-CeilingStage", 1
        )[0]
        ceiling = worker.split("function Start-CeilingStage", 1)[1].split(
            "function Monitor-Stage", 1
        )[0]

        self.assertIn("'ctl', 'task', 'cancel'", rollback)
        self.assertIn("'--action', 'score'", rollback)
        self.assertIn("$termWitnesses", rollback)
        self.assertIn("find-cybench-launch-pids.sh", rollback)
        self.assertIn("/bin/kill -TERM $launchPid", rollback)
        self.assertGreaterEqual(ceiling.count("Stop-DetachedLaunch"), 3)
        self.assertGreaterEqual(ceiling.count("Test-StopRequested"), 2)
        self.assertIn("return 'stopped'", ceiling)

    def test_program_blocks_every_live_cybench_task_before_launch(self) -> None:
        program = source("scripts/start-cybench-program.ps1")
        live_function = program.split("function Get-LiveCybenchTasks", 1)[1].split(
            "function Stop-DetachedCoreLaunch", 1
        )[0]

        self.assertIn("$_.task -eq 'cybench_isolated'", live_function)
        self.assertIn("$null -eq $_.completed_at", live_function)
        self.assertNotIn("$_.model -eq", live_function)
        self.assertIn("Another live Cybench task appeared during program launch", program)

    def test_program_blocks_an_existing_supervisor_before_core_launch(self) -> None:
        program = source("scripts/start-cybench-program.ps1")

        self.assertIn("function Get-LiveCybenchSupervisorProcesses", program)
        self.assertIn("Get-CimInstance -ClassName Win32_Process", program)
        self.assertIn("cybench-supervisor-worker.ps1", program)
        self.assertIn("cybench-supervisor-watchdog.ps1", program)
        self.assertIn("worker or watchdog is already running; refusing", program)
        worker_check = program.index(
            "$existingWorkers = @(Get-LiveCybenchSupervisorProcesses)"
        )
        core_launch = program.index("$launchOutput = @(&")
        self.assertLess(worker_check, core_launch)

    def test_existing_supervisor_requires_the_full_persisted_contract(self) -> None:
        starter = source("scripts/start-cybench-supervisor.ps1")
        worker = source("scripts/cybench-supervisor-worker.ps1")
        contract_fields = (
            "expected_model",
            "expected_model_context_tokens",
            "poll_seconds",
            "final_health_timeout_seconds",
            "core.task_id",
            "core.log_directory",
            "core.expected_agent_policy",
            "core.expected_agent_toolchain",
            "core.expected_compaction_threshold_tokens",
            "core.expected_tool_output_max_bytes",
            "ceiling.expected_agent_policy",
            "ceiling.expected_agent_toolchain",
            "ceiling.expected_compaction_threshold_tokens",
            "ceiling.expected_tool_output_max_bytes",
        )

        for field in contract_fields:
            self.assertIn(f"'{field}'", starter)
        self.assertIn("different contract", starter)
        self.assertIn("pending_stop_request", starter)
        self.assertIn("without a reusable exact state contract", starter)
        self.assertIn("poll_seconds = $PollSeconds", worker)
        self.assertIn(
            "final_health_timeout_seconds = $FinalHealthTimeoutSeconds", worker
        )

    def test_final_health_deadline_always_publishes_attention_required(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")
        verification = worker.split("$stage.status = 'verifying'", 1)[1].split(
            "$lockStream = $null", 1
        )[0]

        self.assertIn("$finalHealthDeadline", verification)
        self.assertIn("-ProbeTimeoutSeconds ([int]$probeTimeoutSeconds)", verification)
        self.assertIn("'/usr/bin/timeout'", worker)
        self.assertIn('Set-Blocked -Reason "$Profile`_final_health_timeout"', verification)
        self.assertIn("return 'blocked'", verification)
        timeout_index = verification.index(
            'Set-Blocked -Reason "$Profile`_final_health_timeout"'
        )
        self.assertLess(
            timeout_index,
            verification.index("return 'blocked'", timeout_index),
        )
        self.assertNotIn("$attempt -le 6", verification)

    def test_completed_at_is_the_authoritative_task_terminal_signal(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")
        monitor = worker.split("function Monitor-Stage", 1)[1].split(
            "$stage.status = 'verifying'", 1
        )[0]

        self.assertIn("if ($null -ne $task.completed_at)", monitor)
        self.assertIn("break", monitor.split("if ($null -ne $task.completed_at)", 1)[1][:80])

    def test_late_io_errors_are_not_misreported_as_lock_conflicts(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")
        io_catch = worker.split("catch [System.IO.IOException]", 1)[1].split(
            "catch {", 1
        )[0]

        self.assertIn("if ($null -eq $lockStream)", io_catch)
        self.assertIn("supervisor_io_exception", io_catch)

    def test_policy_and_toolchain_flow_through_both_stages(self) -> None:
        program = source("scripts/start-cybench-program.ps1")
        starter = source("scripts/start-cybench-supervisor.ps1")
        worker = source("scripts/cybench-supervisor-worker.ps1")
        powershell_wrapper = source("scripts/run-cybench.ps1")
        bash_wrapper = source("scripts/run-cybench.sh")

        self.assertIn("-CoreExpectedAgentPolicy $AgentPolicy", program)
        self.assertIn("-CeilingExpectedAgentPolicy $AgentPolicy", program)
        self.assertIn("-CoreExpectedAgentToolchain $AgentToolchain", program)
        self.assertIn("-CeilingExpectedAgentToolchain $AgentToolchain", program)
        self.assertIn("-AgentPolicy ([string]$script:state.ceiling.expected_agent_policy)", worker)
        self.assertIn(
            "-AgentToolchain ([string]$script:state.ceiling.expected_agent_toolchain)",
            worker,
        )
        self.assertIn("'--agent-policy'", powershell_wrapper)
        self.assertIn("'--agent-toolchain'", powershell_wrapper)
        self.assertIn('-T "agent_policy=${agent_policy}"', bash_wrapper)
        self.assertIn('-T "agent_toolchain=${agent_toolchain}"', bash_wrapper)
        self.assertIn("[string]$AgentPolicy = 'neutral-v1'", program)
        self.assertIn("[string]$AgentPolicy = 'neutral-v1'", powershell_wrapper)
        self.assertIn('agent_policy="neutral-v1"', bash_wrapper)
        self.assertIn("[string]$CoreExpectedAgentPolicy = 'neutral-v1'", starter)
        self.assertIn("[string]$CeilingExpectedAgentPolicy = 'neutral-v1'", starter)
        self.assertIn("[string]$CoreExpectedAgentPolicy = 'neutral-v1'", worker)
        self.assertIn("[string]$CeilingExpectedAgentPolicy = 'neutral-v1'", worker)
        for contract_source in (program, starter, worker, powershell_wrapper):
            self.assertIn("'neutral-v1'", contract_source)
        self.assertIn("agent_prompt_mode=german_neutral_minimal", bash_wrapper)
        self.assertIn('agent_prompt_sha256=${agent_prompt_sha256}', bash_wrapper)

    def test_monitor_observes_pause_without_resuming_or_exiting(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")
        monitor = worker.split("function Monitor-Stage", 1)[1].split(
            "$stage.status = 'verifying'", 1
        )[0]

        self.assertIn("task_pause_observed", monitor)
        self.assertIn("task_pause_released", monitor)
        self.assertIn("process_paused", monitor)
        self.assertIn("paused_now", monitor)
        self.assertIn("quiesced", monitor)
        self.assertIn("held", monitor)
        self.assertIn("$null -ne $_", monitor)
        self.assertIn(
            "-not [string]::IsNullOrWhiteSpace([string]$_)",
            monitor,
        )
        pause_block = monitor.split("if ($taskPaused)", 1)[1].split(
            "elseif ($taskPauseActive)", 1
        )[0]
        self.assertNotIn("task', 'resume", pause_block)
        self.assertNotIn("return 'blocked'", pause_block)

    def test_technical_sample_failure_remains_monitored_until_clean_finalize(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")
        monitor = worker.split("function Monitor-Stage", 1)[1].split(
            "$stage.status = 'verifying'", 1
        )[0]
        technical = monitor.split("$managedBlockReason = if", 1)[1].split(
            "if ($taskPaused)", 1
        )[0]

        self.assertIn("technical_sample_status_detected", technical)
        self.assertIn("technical_task_soft_paused", technical)
        self.assertIn("task_pause.quiesced", technical)
        self.assertIn("'ctl', 'task', 'cancel'", technical)
        self.assertIn("'--action', 'score'", technical)
        self.assertIn("technical_task_finalize_requested", technical)
        self.assertNotIn("return 'blocked'", technical)

    def test_integrity_anomalies_are_latched_across_final_health(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")
        monitor = worker.split("function Monitor-Stage", 1)[1].split(
            "$lockStream = $null", 1
        )[0]

        for reason in (
            "parallel_cybench_task_detected",
            "duplicate_task_id_detected",
            "unexpected_model",
        ):
            self.assertIn(reason, monitor)
        self.assertIn("$stage.integrity_block", monitor)
        self.assertIn("if ($null -ne $stage.integrity_block)", monitor)
        self.assertIn("Stop-ExactDetachedTask", worker)
        self.assertIn("Wait-ForDetachedTaskToStop", worker)
        self.assertIn("'ctl', 'task', 'cancel', $TaskId, '--json'", worker)

    def test_final_health_complete_requires_zero_exit_code(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")

        self.assertIn("$health.exit_code -ne 0", worker)
        self.assertIn("final_health_exit_mismatch", worker)

    def test_core_rollback_never_cancels_by_model_identity_alone(self) -> None:
        program = source("scripts/start-cybench-program.ps1")
        rollback = program.split("function Stop-DetachedCoreLaunch", 1)[1].split(
            "function Get-LiveCybenchSupervisorProcesses", 1
        )[0]

        self.assertNotIn(
            "Where-Object { [string]$_.model -eq $expectedModel }", rollback
        )
        self.assertIn("$ExpectedWslLogDirectory", rollback)
        self.assertIn("find-cybench-launch-pids.sh", rollback)
        self.assertIn("Stop-ExactInspectTask", program)
        self.assertIn("Wait-ForTaskToLeaveLiveSet", program)

    def test_launch_process_helper_matches_exact_log_dir_argument_pair(self) -> None:
        helper = ROOT / "scripts" / "find-cybench-launch-pids.sh"
        expected = "/mnt/c/work/artifacts/logs/abc-123-cybench"
        with tempfile.TemporaryDirectory() as temporary:
            proc_root = Path(temporary)
            fixtures = {
                101: [
                    "/venv/bin/python",
                    "-m",
                    "inspect_ai._cli.main",
                    "eval",
                    "--log-dir",
                    expected,
                ],
                102: ["bash", "helper", "inspect", "eval", expected],
                103: [
                    "/venv/bin/inspect",
                    "eval",
                    "--log-dir",
                    "/mnt/c/work/artifacts/logs/other-cybench",
                ],
                104: [
                    "/venv/bin/python",
                    "inspect_ai._cli.main",
                    "eval",
                    "--log-dir",
                    expected,
                ],
            }
            for pid, arguments in fixtures.items():
                directory = proc_root / str(pid)
                directory.mkdir()
                (directory / "cmdline").write_bytes(
                    b"\0".join(argument.encode() for argument in arguments) + b"\0"
                )
            completed = subprocess.run(
                ["bash", str(helper), expected, str(proc_root)],
                check=True,
                text=True,
                capture_output=True,
            )

        self.assertEqual(completed.stdout.splitlines(), ["101"])

    def test_runner_process_helper_matches_exact_run_id_argument_pair(self) -> None:
        helper = ROOT / "scripts" / "find-cybench-runner-pids.sh"
        run_id = "20260825T010203004Z-abc123"
        with tempfile.TemporaryDirectory() as temporary:
            proc_root = Path(temporary)
            fixtures = {
                201: [
                    "bash",
                    "scripts/run-cybench.sh",
                    "--profile",
                    "ceiling",
                    "--run-id",
                    run_id,
                ],
                202: ["bash", "other.sh", "--run-id", run_id],
                203: [
                    "bash",
                    "scripts/run-cybench.sh",
                    "--run-id",
                    "different-run",
                ],
                204: ["python", "-c", "scripts/run-cybench.sh", "--run-id", run_id],
            }
            for pid, arguments in fixtures.items():
                directory = proc_root / str(pid)
                directory.mkdir()
                (directory / "cmdline").write_bytes(
                    b"\0".join(argument.encode() for argument in arguments) + b"\0"
                )
            completed = subprocess.run(
                ["bash", str(helper), run_id, str(proc_root)],
                check=True,
                text=True,
                capture_output=True,
            )

        self.assertEqual(completed.stdout.splitlines(), ["201"])

    def test_monitor_emits_recovery_and_sample_transition_events(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")

        for event in (
            "endpoint_unavailable",
            "endpoint_recovered",
            "inspect_control_unavailable",
            "inspect_control_recovered",
            "sample_started",
            "sample_left_running_state",
            "sample_poll_unavailable",
            "sample_poll_recovered",
        ):
            self.assertIn(event, worker)
        for field in (
            "last_activity_at_unix",
            "idle_seconds",
            "activity",
            "event_count",
            "turn_count",
        ):
            self.assertIn(field, worker)

    def test_live_compaction_read_is_bounded_metadata_only_and_best_effort(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")
        pager = worker.split("function Get-PagedSampleEvents", 1)[1].split(
            "function Get-CompactionTelemetry", 1
        )[0]
        telemetry = worker.split("function Get-CompactionTelemetry", 1)[1].split(
            "function Test-Endpoint", 1
        )[0]

        self.assertIn("Get-PagedSampleEvents", telemetry)
        self.assertIn("-Type 'compaction'", telemetry)
        self.assertIn("-FromStart", telemetry)
        self.assertIn("-Full", telemetry)
        self.assertIn("'--cursor'", pager)
        self.assertIn("$page.done", pager)
        self.assertIn("$nextCursor -eq $cursor", pager)
        self.assertIn("$pageCount -lt $MaxPages", pager)
        self.assertNotIn("$null -eq $page.next", telemetry)
        self.assertIn("[DateTimeOffset]::Parse", telemetry)
        self.assertIn("ToUnixTimeMilliseconds", telemetry)
        self.assertIn("'R', [Globalization.CultureInfo]::InvariantCulture", telemetry)
        self.assertIn("[Globalization.CultureInfo]::InvariantCulture", telemetry)
        self.assertIn("$event.tokens_before", telemetry)
        self.assertIn("$event.tokens_after", telemetry)
        self.assertIn("$metadata.messages_before", telemetry)
        self.assertIn("$metadata.messages_after", telemetry)
        self.assertIn("post_run_review_required", telemetry)
        self.assertNotIn("--content", telemetry)
        self.assertIn("/usr/bin/timeout", worker)
        self.assertIn("complete_event_history = [bool]$history.terminal_done", telemetry)

        monitor = worker.split("function Monitor-Stage", 1)[1].split(
            "$stage.status = 'verifying'", 1
        )[0]
        trace_catch = monitor.split(
            "# Live transcript telemetry is best-effort", 1
        )[1].split("$traceCheckAt", 1)[0]
        self.assertNotIn("Set-Blocked", trace_catch)
        self.assertNotIn("return 'blocked'", trace_catch)

    def test_gpu_probe_is_bounded_read_only_and_best_effort(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")
        common = source("scripts/RunPod.Common.psm1")
        gpu = worker.split("function Get-GpuTelemetry", 1)[1].split(
            "function Test-Endpoint", 1
        )[0]
        monitor = worker.split("function Monitor-Stage", 1)[1].split(
            "$stage.status = 'verifying'", 1
        )[0]

        self.assertIn("timeout --signal=TERM --kill-after=2s 10s", gpu)
        self.assertIn("nvidia-smi --query-gpu=", gpu)
        self.assertIn("--format=csv,noheader,nounits", gpu)
        self.assertIn("Invoke-RunPodSshBounded", gpu)
        self.assertIn("-TimeoutSeconds 40", gpu)
        self.assertNotIn("Set-Blocked", gpu)
        self.assertIn("gpu_telemetry_unavailable", monitor)
        self.assertIn("gpu_telemetry_recovered", monitor)
        self.assertIn("AddSeconds(300)", monitor)
        self.assertIn("ServerAliveInterval=10", common)
        self.assertIn("ServerAliveCountMax=2", common)
        self.assertIn("$process.WaitForExit($TimeoutSeconds * 1000)", common)
        self.assertIn("$process.Kill()", common)

    def test_status_distinguishes_current_sample_from_cumulative_usage(self) -> None:
        status = source("scripts/cybench-supervisor-status.ps1")
        worker = source("scripts/cybench-supervisor-worker.ps1")

        self.assertIn("Current sample: $($current.sample_id)", status)
        self.assertIn("Current sample (legacy)", status)
        self.assertIn("Cumulative tokens/messages", status)
        self.assertIn("cumulative_total_tokens", worker)
        self.assertIn("cumulative_total_messages", worker)
        self.assertNotIn("$state.progress.current_sample -join", status)
        self.assertIn("Task pause:", status)
        self.assertIn("GPU:", status)
        self.assertIn("Active transient issues:", status)

    def test_transient_health_issues_preserve_concurrent_failures(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")

        for reason in (
            "endpoint_check_failed",
            "gpu_telemetry_failed",
            "ctl_poll_failed",
            "sample_poll_failed",
        ):
            self.assertIn(f"Set-TransientHealthIssue -Reason '{reason}'", worker)
            self.assertIn(f"Clear-TransientHealthIssue -Reason '{reason}'", worker)
        for event in (
            "endpoint_recovered",
            "gpu_telemetry_recovered",
            "inspect_control_recovered",
            "sample_poll_recovered",
        ):
            self.assertIn(event, worker)
        self.assertIn("active_transient_issues[$Reason] = $issue", worker)
        self.assertIn("active_transient_issues.Remove($Reason)", worker)
        self.assertIn("active_transient_issues.GetEnumerator()", worker)
        self.assertIn(
            "$script:state.last_issue = Get-LatestTransientHealthIssue", worker
        )

    def test_documentation_pipeline_is_bound_in_run_and_health_contracts(self) -> None:
        adapter = source("evals/cybench.py")
        worker = source("scripts/cybench-supervisor-worker.ps1")
        bash_wrapper = source("scripts/run-cybench.sh")
        harness_smoke = source("scripts/run-cybench-harness-smoke.sh")

        self.assertIn(
            "--metadata documentation_pipeline_id=iterative-active-window",
            bash_wrapper,
        )
        self.assertIn(
            "--metadata documentation_pipeline_version=3",
            bash_wrapper,
        )
        for contract in (worker, harness_smoke):
            self.assertIn("--expected-documentation-pipeline-id", contract)
            self.assertIn("--expected-documentation-pipeline-version", contract)
        self.assertIn(
            "documentation_error = classified_documentation_error(ex)",
            adapter,
        )
        self.assertNotIn(
            'documentation_error = f"{type(ex).__name__}: {ex}"',
            adapter,
        )

    def test_model_api_read_timeout_is_versioned_and_supervisor_bound(self) -> None:
        bash_wrapper = source("scripts/run-cybench.sh")
        harness_smoke = source("scripts/run-cybench-harness-smoke.sh")
        starter = source("scripts/start-cybench-supervisor.ps1")
        worker = source("scripts/cybench-supervisor-worker.ps1")
        program = source("scripts/start-cybench-program.ps1")

        self.assertIn(
            'model_api_timeout_policy="phase-limit-owned-v1"',
            bash_wrapper,
        )
        self.assertIn(
            "solve_time_limit_seconds + model_api_client_timeout_margin_seconds",
            bash_wrapper,
        )
        self.assertIn(
            '-M "client_timeout=${model_api_client_timeout_seconds}"',
            bash_wrapper,
        )
        self.assertIn(
            '--metadata "model_api_timeout_policy=${model_api_timeout_policy}"',
            bash_wrapper,
        )
        self.assertIn(
            '--metadata "model_api_client_timeout_seconds=${model_api_client_timeout_seconds}"',
            bash_wrapper,
        )
        self.assertIn('-M "client_timeout=${model_api_client_timeout_seconds}"', harness_smoke)
        for contract in (harness_smoke, starter, worker):
            self.assertIn("--expected-model-api-timeout-policy", contract)
            self.assertIn("--expected-model-api-client-timeout-seconds", contract)
        for contract in (starter, worker):
            self.assertIn("ExpectedModelApiTimeoutPolicy", contract)
            self.assertIn("ExpectedModelApiClientTimeoutSeconds", contract)
        self.assertIn(
            "-ExpectedModelApiTimeoutPolicy phase-limit-owned-v1",
            program,
        )
        self.assertIn(
            "-ExpectedModelApiClientTimeoutSeconds 7500",
            program,
        )

    def test_supervisor_events_are_rotated_and_bound_to_one_plan(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")

        self.assertIn("function Archive-ExistingEventLog", worker)
        self.assertIn("events-archive", worker)
        self.assertIn("previous_event_archive = $null", worker)
        self.assertIn(
            "$script:state.previous_event_archive = Archive-ExistingEventLog",
            worker,
        )
        self.assertIn("plan_id = [string]$script:state.plan_id", worker)
        archive_call = worker.index(
            "$script:state.previous_event_archive = Archive-ExistingEventLog"
        )
        first_event = worker.index("Write-EventRecord -Name 'supervisor_started'")
        self.assertLess(archive_call, first_event)


if __name__ == "__main__":
    unittest.main()

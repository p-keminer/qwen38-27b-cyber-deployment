from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STARTER = ROOT / "scripts" / "start-cybench-supervisor.ps1"
WORKER = ROOT / "scripts" / "cybench-supervisor-worker.ps1"


def source(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def powershell_path(path: Path) -> str:
    resolved = path.resolve()
    posix = resolved.as_posix()
    if posix.startswith("/mnt/") and len(posix) > 6:
        return f"{posix[5].upper()}:\\" + posix[7:].replace("/", "\\")
    return str(resolved)


def supervisor_binding_fragment() -> str:
    starter = source(STARTER)
    fragment = "function ConvertTo-WslPath" + starter.split(
        "function ConvertTo-WslPath", 1
    )[1].split("function Get-StateValue", 1)[0]

    # The production script runs on Windows, where GetFullPath canonicalizes
    # drive-rooted paths. Ubuntu CI exercises the extracted binding logic in
    # pwsh, so emulate only that normalization while retaining its strict
    # drive-path validation and WSL conversion.
    windows_normalization = "$fullPath = [IO.Path]::GetFullPath($WindowsPath)"
    if fragment.count(windows_normalization) != 1:
        raise AssertionError("Unexpected ConvertTo-WslPath implementation")
    portable_normalization = """$fullPath = if ([IO.Path]::DirectorySeparatorChar -eq '/') {
        $WindowsPath.Replace('/', '\\')
    }
    else {
        [IO.Path]::GetFullPath($WindowsPath)
    }"""
    return fragment.replace(windows_normalization, portable_normalization, 1)


class CybenchSupervisorBindingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.powershell = (
            shutil.which("pwsh")
            or shutil.which("powershell.exe")
            or shutil.which("powershell")
        )
        if cls.powershell is None:
            raise unittest.SkipTest("PowerShell is required for binding tests")

    def invoke_exact_binding(self, tasks: list[dict[str, object]]) -> subprocess.CompletedProcess[str]:
        fragment = supervisor_binding_fragment()
        payload = json.dumps({"tasks": tasks})
        harness = f"""
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$expectedModel = 'openai-api/llamacpp/qwen3.8-27b-uncensored-q6'
$fixture = @'
{payload}
'@ | ConvertFrom-Json
function Invoke-BoundedInspectTaskList {{ return $fixture }}
{fragment}
try {{
    $result = Get-ExactLiveCoreTask `
        -TaskId 'task-1' `
        -ResolvedLogDirectory 'C:/work/logs/launch-cybench'
    [Console]::Out.Write("OK:$([int]$result.pid)")
    exit 0
}}
catch {{
    [Console]::Error.Write("ERR:$($_.Exception.Message)")
    exit 2
}}
"""
        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            script = Path(temporary) / "binding.ps1"
            script.write_text(harness, encoding="utf-8")
            return subprocess.run(
                [
                    self.powershell,
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    powershell_path(script),
                ],
                text=True,
                encoding="utf-8",
                errors="replace",
                capture_output=True,
                check=False,
            )

    def invoke_contract_health(
        self, *, state: str, provider_exit_code: int
    ) -> subprocess.CompletedProcess[str]:
        fragment = supervisor_binding_fragment()
        harness = f"""
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = 'C:\\work'
$expectedModel = 'openai-api/llamacpp/qwen3.8-27b-uncensored-q6'
$expectedModelContextTokens = 262144
$ExpectedModelApiTimeoutPolicy = 'phase-limit-owned-v1'
$ExpectedModelApiClientTimeoutSeconds = 7500
$CoreExpectedAgentPolicy = 'neutral-v1'
$CoreExpectedAgentToolchain = 'upstream-static-v1'
$CoreExpectedCompactionThresholdTokens = 160000
$CoreExpectedToolOutputMaxBytes = 16384
$script:capturedArguments = @()
{fragment}
function Invoke-BoundedCoreHealth {{
    param([string[]]$Arguments)
    $script:capturedArguments = @($Arguments)
    return [pscustomobject]@{{
        exit_code = {provider_exit_code}
        text = '{{"state":"{state}"}}'
    }}
}}
try {{
    Assert-LiveCoreRunContract `
        -TaskId 'task-1' `
        -ResolvedLogDirectory 'C:\\work\\logs\\launch-cybench'
    [Console]::Out.Write("OK|$($script:capturedArguments -join '|')")
    exit 0
}}
catch {{
    [Console]::Error.Write("ERR:$($_.Exception.Message)")
    exit 2
}}
"""
        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            script = Path(temporary) / "health-binding.ps1"
            script.write_text(harness, encoding="utf-8")
            return subprocess.run(
                [
                    self.powershell,
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    powershell_path(script),
                ],
                text=True,
                encoding="utf-8",
                errors="replace",
                capture_output=True,
                check=False,
            )

    @staticmethod
    def task(**overrides: object) -> dict[str, object]:
        item: dict[str, object] = {
            "task": "cybench_isolated",
            "task_id": "task-1",
            "model": "openai-api/llamacpp/qwen3.8-27b-uncensored-q6",
            "pid": 1234,
            "completed_at": None,
            "log_location": "/mnt/c/work/logs/launch-cybench/sample.eval",
        }
        item.update(overrides)
        return item

    def test_exact_binding_accepts_only_one_fully_matching_live_task(self) -> None:
        accepted = self.invoke_exact_binding([self.task()])
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertIn("OK:1234", accepted.stdout)

        rejected_fixtures = (
            [self.task(task_id="other")],
            [self.task(model="wrong-model")],
            [self.task(pid=0)],
            [self.task(completed_at="2026-08-25T00:00:00Z")],
            [self.task(log_location="/mnt/c/work/logs/launch-cybench-sibling/x.eval")],
            [self.task(), self.task(task_id="other", pid=5678)],
        )
        for fixture in rejected_fixtures:
            with self.subTest(fixture=fixture):
                rejected = self.invoke_exact_binding(fixture)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("sole exact live Cybench task", rejected.stderr)

    def test_validated_pid_is_the_initial_worker_identity(self) -> None:
        starter = source(STARTER)
        worker = source(WORKER)

        self.assertIn("$validatedCoreTask = Get-ExactLiveCoreTask", starter)
        self.assertIn("$validatedExistingTask = Get-ExactLiveCoreTask", starter)
        self.assertIn("$coreInspectPid = [int]$validatedCoreTask.pid", starter)
        self.assertIn("'-CoreInspectPid', [string]$coreInspectPid", starter)
        self.assertIn("[int]$CoreInspectPid", worker)
        self.assertIn("inspect_pid = $CoreInspectPid", worker)
        self.assertIn("core.inspect_pid", starter)
        self.assertIn("$process.CommandLine).Contains($existingNonce)", starter)

    def test_live_core_policy_contract_is_checked_before_start_and_reuse(self) -> None:
        starter = source(STARTER)

        self.assertIn("function Assert-LiveCoreRunContract", starter)
        self.assertGreaterEqual(starter.count("Assert-LiveCoreRunContract"), 3)
        for argument in (
            "--expected-profile', 'core'",
            "--expected-task-id', $TaskId",
            "--expected-agent-policy', $CoreExpectedAgentPolicy",
            "--expected-agent-toolchain', $CoreExpectedAgentToolchain",
            "--expected-model-api-timeout-policy', $ExpectedModelApiTimeoutPolicy",
            "--expected-model-api-client-timeout-seconds'",
            "--expected-documentation-pipeline-version', '3'",
            "--expected-context-management', 'summary_compaction'",
            "--expected-compaction-threshold-tokens'",
            "--expected-compaction-summary-max-tokens', '4096'",
            "--expected-model-context-tokens'",
        ):
            self.assertIn(argument, starter)
        self.assertIn("$lastState -eq 'running'", starter)

        accepted = self.invoke_contract_health(state="running", provider_exit_code=0)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertIn("--expected-profile|core", accepted.stdout)
        self.assertIn("--expected-agent-policy|neutral-v1", accepted.stdout)
        self.assertIn(
            "--expected-model-api-timeout-policy|phase-limit-owned-v1",
            accepted.stdout,
        )
        self.assertIn(
            "--expected-model-api-client-timeout-seconds|7500",
            accepted.stdout,
        )

        rejected = self.invoke_contract_health(
            state="technical_error", provider_exit_code=2
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("does not match the required running Core policy", rejected.stderr)

    def test_unfinished_plan_blocks_implicit_reinitialization(self) -> None:
        starter = source(STARTER)
        program = source(ROOT / "scripts" / "start-cybench-program.ps1")

        self.assertIn("An unfinished supervisor plan exists without its exact live worker", starter)
        self.assertIn("Existing supervisor state is unreadable", starter)
        self.assertIn("$supervisorStatePath", program)
        self.assertIn("An unfinished supervisor plan exists; refusing a new Core launch", program)
        self.assertIn("$existingPlanIsTerminal", starter)
        self.assertIn("$existingPlanIsTerminal", program)
        self.assertIn("state -eq 'supervisor_stopped'", starter)
        self.assertIn("state -eq 'complete'", program)

    def test_terminal_log_mismatch_is_latched_before_completion(self) -> None:
        worker = source(WORKER)
        monitor = worker.split("function Monitor-Stage", 1)[1].split(
            "$stage.status = 'verifying'", 1
        )[0]

        mismatch = monitor.index("task_log_location_mismatch")
        terminal = monitor.index("if ($null -ne $task.completed_at)")
        self.assertLess(mismatch, terminal)
        self.assertIn("$stage.integrity_block", monitor[mismatch - 500 : terminal])
        self.assertIn("Set-Blocked -Reason $integrityBlockReason", monitor)

    def test_monitoring_outages_are_bounded_and_exactly_contained(self) -> None:
        worker = source(WORKER)

        self.assertIn("$script:monitoringOutageGraceSeconds", worker)
        self.assertIn("ctl_monitoring_outage_timeout", worker)
        self.assertIn("sample_monitoring_outage_timeout", worker)
        self.assertIn("Invoke-MonitoringOutageContainment", worker)
        self.assertIn("Stop-DetachedLaunch", worker)
        self.assertIn("monitoring_outage_contained", worker)
        self.assertIn("ctl_outage_started_at_utc", worker)
        self.assertIn("sample_poll_outage_started_at_utc", worker)
        self.assertIn("$script:monitoringOutageGraceSeconds = 600", worker)

    def test_long_endpoint_probe_has_a_bounded_heartbeat_lease(self) -> None:
        worker = source(WORKER)
        watchdog = source(ROOT / "scripts" / "cybench-supervisor-watchdog.ps1")

        self.assertIn("active_probe = [ordered]@{", worker)
        self.assertIn("deadline_utc = $activeProbeStartedAt.AddSeconds(420)", worker)
        self.assertIn("finally {", worker)
        self.assertIn("$script:state.health.active_probe = $null", worker)
        self.assertIn("$activeProbeDeadline", watchdog)
        self.assertIn("[DateTime]::UtcNow -le $activeProbeDeadline", watchdog)
        self.assertIn("function Get-ValidActiveProbeDeadline", watchdog)
        self.assertIn("($deadline - $startedAt).TotalSeconds -gt 420", watchdog)

    def test_long_event_pagination_observes_bound_stop_requests(self) -> None:
        worker = source(WORKER)
        pager = worker.split("function Get-PagedSampleEvents", 1)[1].split(
            "function Get-CompactionTelemetry", 1
        )[0]

        self.assertGreaterEqual(pager.count("Test-StopRequested"), 2)
        self.assertIn("Supervisor stop requested during event pagination", pager)

    def test_kill_escalation_revalidates_witness_and_confirms_death(self) -> None:
        worker = source(WORKER)
        program = source(ROOT / "scripts" / "start-cybench-program.ps1")

        for contract in (worker, program):
            self.assertIn("$killWitnesses", contract)
            self.assertIn("find-cybench-launch-pids.sh", contract)
            self.assertIn("-ne $launchPid", contract)
            self.assertIn("could not verify process death after KILL", contract)

    def test_term_escalation_uses_the_same_exact_argv_witness(self) -> None:
        worker = source(WORKER)
        program = source(ROOT / "scripts" / "start-cybench-program.ps1")

        for contract in (worker, program):
            self.assertIn("$termWitnesses", contract)
            self.assertIn("find-cybench-launch-pids.sh", contract)
            self.assertIn("lost its exact process witness before TERM", contract)

    def test_watchdog_preserves_pid_ownership_and_acknowledges_stop_in_main_state(self) -> None:
        watchdog = source(ROOT / "scripts" / "cybench-supervisor-watchdog.ps1")

        self.assertIn("$expectedInspectPid", watchdog)
        self.assertIn("[int]$_.pid -eq $expectedInspectPid", watchdog)
        self.assertIn("function Save-SupervisorStoppedState", watchdog)
        self.assertGreaterEqual(
            watchdog.count("Save-SupervisorStoppedState -SupervisorState"), 6
        )
        self.assertIn("$latest.desired_state = 'stopped'", watchdog)
        self.assertIn("$latest.state = 'supervisor_stopped'", watchdog)

    def test_worker_rejects_nonpositive_live_inspect_pid(self) -> None:
        worker = source(WORKER)

        self.assertIn("inspect_pid_invalid", worker)
        self.assertIn("inspect_pid_invalid_detected", worker)


if __name__ == "__main__":
    unittest.main()

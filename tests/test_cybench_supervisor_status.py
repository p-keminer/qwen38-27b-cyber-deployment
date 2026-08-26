from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STATUS_SCRIPT = ROOT / "scripts" / "cybench-supervisor-status.ps1"


def powershell_path(path: Path) -> str:
    resolved = path.resolve()
    posix = resolved.as_posix()
    if posix.startswith("/mnt/") and len(posix) > 6:
        return f"{posix[5].upper()}:\\" + posix[7:].replace("/", "\\")
    return str(resolved)


class CybenchSupervisorStatusHeartbeatTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.powershell = (
            shutil.which("pwsh")
            or shutil.which("powershell.exe")
            or shutil.which("powershell")
        )
        if cls.powershell is None:
            raise unittest.SkipTest("PowerShell is required for the status regression test")

    def run_status(
        self,
        *,
        poll_seconds: int,
        worker_age_seconds: int,
        watchdog_age_seconds: int,
        ceiling_status: str = "pending",
        active_probe_deadline_seconds: int | None = None,
        active_probe_started_seconds_ago: int = 0,
        active_probe_name: str = "endpoint_check",
    ) -> subprocess.CompletedProcess[str]:
        now = datetime.now(timezone.utc)
        startup_nonce = "a" * 32
        watchdog_nonce = "b" * 32
        worker_pid = 41001
        watchdog_pid = 41002

        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            state_dir = root / ".runpod" / "cybench-supervisor"
            scripts.mkdir(parents=True)
            state_dir.mkdir(parents=True)
            shutil.copy2(STATUS_SCRIPT, scripts / STATUS_SCRIPT.name)

            health = None
            if active_probe_deadline_seconds is not None:
                health = {
                    "active_probe": {
                        "name": active_probe_name,
                        "started_at_utc": (
                            now
                            - timedelta(seconds=active_probe_started_seconds_ago)
                        ).isoformat(),
                        "deadline_utc": (
                            now + timedelta(seconds=active_probe_deadline_seconds)
                        ).isoformat(),
                    }
                }
            state = {
                "state": "monitoring_core",
                "desired_state": "running",
                "worker_pid": worker_pid,
                "startup_nonce": startup_nonce,
                "watchdog_nonce": watchdog_nonce,
                "updated_at_utc": (
                    now - timedelta(seconds=worker_age_seconds)
                ).isoformat(),
                "poll_seconds": poll_seconds,
                "expected_model": "test-model",
                "ceiling": {"status": ceiling_status},
                "progress": None,
                "health": health,
                "last_issue": None,
            }
            watchdog_state = {
                "state": "watching",
                "watchdog_pid": watchdog_pid,
                "worker_pid": worker_pid,
                "watchdog_nonce": watchdog_nonce,
                "updated_at_utc": (
                    now - timedelta(seconds=watchdog_age_seconds)
                ).isoformat(),
                "last_issue": None,
            }
            (state_dir / "state.json").write_text(
                json.dumps(state), encoding="utf-8"
            )
            (state_dir / "watchdog.json").write_text(
                json.dumps(watchdog_state), encoding="utf-8"
            )

            wrapper = root / "invoke-status.ps1"
            wrapper.write_text(
                f"""
function Get-CimInstance {{
    [CmdletBinding()]
    param([string]$ClassName, [string]$Filter)
    if ($Filter -eq 'ProcessId = {worker_pid}') {{
        return [pscustomobject]@{{
            CommandLine = 'powershell -File cybench-supervisor-worker.ps1 -StartupNonce {startup_nonce}'
        }}
    }}
    if ($Filter -eq 'ProcessId = {watchdog_pid}') {{
        return [pscustomobject]@{{
            CommandLine = 'powershell -File cybench-supervisor-watchdog.ps1 -StartupNonce {startup_nonce} -WatchdogNonce {watchdog_nonce} -WorkerPid {worker_pid}'
        }}
    }}
    return $null
}}
& '{powershell_path(scripts / STATUS_SCRIPT.name)}'
""",
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    self.powershell,
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    powershell_path(wrapper),
                ],
                text=True,
                encoding="utf-8",
                errors="replace",
                capture_output=True,
                check=False,
            )

        return completed

    def test_poll_multiplier_applies_to_worker_heartbeat(self) -> None:
        completed = self.run_status(
            poll_seconds=120,
            worker_age_seconds=350,
            watchdog_age_seconds=0,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_poll_multiplier_applies_to_watchdog_heartbeat(self) -> None:
        completed = self.run_status(
            poll_seconds=120,
            worker_age_seconds=0,
            watchdog_age_seconds=350,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_worker_uses_300_second_floor(self) -> None:
        completed = self.run_status(
            poll_seconds=10,
            worker_age_seconds=240,
            watchdog_age_seconds=0,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_watchdog_uses_180_second_floor(self) -> None:
        completed = self.run_status(
            poll_seconds=10,
            worker_age_seconds=0,
            watchdog_age_seconds=240,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "Active supervisor liveness or heartbeat binding is invalid.",
            completed.stderr,
        )

    def test_ceiling_launch_allows_the_worker_900_seconds(self) -> None:
        completed = self.run_status(
            poll_seconds=10,
            worker_age_seconds=600,
            watchdog_age_seconds=0,
            ceiling_status="launching",
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_active_probe_lease_covers_a_long_bounded_operation(self) -> None:
        active = self.run_status(
            poll_seconds=10,
            worker_age_seconds=400,
            watchdog_age_seconds=0,
            active_probe_deadline_seconds=60,
        )
        expired = self.run_status(
            poll_seconds=10,
            worker_age_seconds=400,
            watchdog_age_seconds=0,
            active_probe_deadline_seconds=-1,
        )

        self.assertEqual(active.returncode, 0, active.stderr)
        self.assertNotEqual(expired.returncode, 0)

    def test_active_probe_lease_is_strictly_bounded_and_named(self) -> None:
        too_long = self.run_status(
            poll_seconds=10,
            worker_age_seconds=400,
            watchdog_age_seconds=0,
            active_probe_started_seconds_ago=1,
            active_probe_deadline_seconds=600,
        )
        wrong_name = self.run_status(
            poll_seconds=10,
            worker_age_seconds=400,
            watchdog_age_seconds=0,
            active_probe_deadline_seconds=60,
            active_probe_name="unbounded_probe",
        )
        future_start = self.run_status(
            poll_seconds=10,
            worker_age_seconds=400,
            watchdog_age_seconds=0,
            active_probe_started_seconds_ago=-60,
            active_probe_deadline_seconds=120,
        )

        for completed in (too_long, wrong_name, future_start):
            self.assertNotEqual(completed.returncode, 0)


if __name__ == "__main__":
    unittest.main()

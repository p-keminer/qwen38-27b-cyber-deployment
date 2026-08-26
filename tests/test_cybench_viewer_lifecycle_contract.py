from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class CybenchViewerLifecycleContractTests(unittest.TestCase):
    def test_wsl_viewer_uses_exact_process_identity_and_a_session(self) -> None:
        script = source("scripts/view-cybench.sh")

        self.assertIn('expected_command=(', script)
        self.assertIn('mapfile -d \'\' -t actual_command', script)
        self.assertIn('actual_command[index]', script)
        self.assertIn('expected_command[index]', script)
        self.assertIn('export UV_PROJECT_ENVIRONMENT="${venv_dir}"', script)
        self.assertIn('expected_child_command=(', script)
        self.assertIn('find_owned_child_pids', script)
        self.assertIn('find_matching_child_pids', script)
        self.assertIn('owned_kind="orphan_child"', script)
        self.assertIn('stop_orphan_child', script)
        self.assertIn('[[ "${response}" == *Inspect* ]]', script)
        self.assertIn('nohup setsid "${expected_command[@]}"', script)
        self.assertIn('flock --exclusive --wait 20', script)
        self.assertIn('lifecycle.lock', script)
        self.assertIn('kill -TERM -- "-${pid}"', script)
        self.assertIn('Refusing ambiguous Inspect View ownership', script)
        self.assertIn('occupied by a process not owned by this project', script)

    def test_start_migrates_legacy_windows_pid_only_after_wsl_check(self) -> None:
        starter = source("scripts/cybench-view.ps1")

        status_call = starter.index("$status = Invoke-WslViewLifecycle -Action status")
        start_call = starter.index("$start = Invoke-WslViewLifecycle -Action start")
        legacy_removal = starter.index("Remove-Item -LiteralPath $legacyPidPath")
        self.assertLess(status_call, start_call)
        self.assertLess(start_call, legacy_removal)
        self.assertNotIn("Set-Content -LiteralPath", starter)
        self.assertNotIn("PassThru = $true", starter)

    def test_start_uses_native_exit_code_despite_harmless_wsl_stderr(self) -> None:
        starter = source("scripts/cybench-view.ps1")

        helper = starter[
            starter.index("function Invoke-WslViewLifecycle") :
            starter.index("$status = Invoke-WslViewLifecycle")
        ]
        self.assertIn("$ErrorActionPreference = 'Continue'", helper)
        self.assertIn("$exitCode = $LASTEXITCODE", helper)
        self.assertIn("$ErrorActionPreference = $previousErrorActionPreference", helper)
        self.assertIn("exit_code = $exitCode", helper)
        self.assertNotIn("2>$null", helper)

    def test_stop_delegates_to_validated_wsl_owner(self) -> None:
        stopper = source("scripts/cybench-view-stop.ps1")

        self.assertIn("view-cybench.sh stop", stopper)
        self.assertIn("$ErrorActionPreference = 'Continue'", stopper)
        self.assertIn("$exitCode = $LASTEXITCODE", stopper)
        self.assertIn(
            "$ErrorActionPreference = $previousErrorActionPreference",
            stopper,
        )
        self.assertIn("if ($exitCode -ne 0)", stopper)
        self.assertNotIn("2>$null", stopper)
        self.assertNotIn("Get-Process", stopper)
        self.assertNotIn("Stop-Process", stopper)


if __name__ == "__main__":
    unittest.main()

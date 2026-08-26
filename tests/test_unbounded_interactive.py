from __future__ import annotations

import inspect
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from inspect_ai.model import get_model, get_model_info

from evals.cybench import (
    RUNTIME_MODE_BENCHMARK,
    RUNTIME_MODE_INTERACTIVE,
    cybench_isolated,
    solve_then_document,
)
from evals.llamacpp_unbounded import LLAMACPP_UNBOUNDED_PROVIDER


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def source(relative_path: str) -> str:
    return (PROJECT_ROOT / relative_path).read_text(encoding="utf-8")


def parse_jsonc(document: str) -> dict[str, object]:
    """Remove line comments without damaging // inside JSON strings."""
    output: list[str] = []
    in_string = False
    escaped = False
    index = 0
    while index < len(document):
        character = document[index]
        if in_string:
            output.append(character)
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            index += 1
            continue
        if character == '"':
            in_string = True
            output.append(character)
            index += 1
            continue
        if character == "/" and document[index : index + 2] == "//":
            newline = document.find("\n", index + 2)
            if newline == -1:
                break
            output.append("\n")
            index = newline + 1
            continue
        output.append(character)
        index += 1
    return json.loads("".join(output))


class UnboundedProviderTests(unittest.IsolatedAsyncioTestCase):
    async def test_provider_disables_read_timeout_and_bounds_infrastructure(self) -> None:
        model = get_model(
            f"{LLAMACPP_UNBOUNDED_PROVIDER}/qwen3.8-27b-uncensored-q6",
            base_url="http://127.0.0.1:1/v1",
            api_key="unit-test-only",
            memoize=False,
        )
        try:
            self.assertIsNone(model.api.client_timeout)
            timeout = model.api.client._client.timeout
            self.assertEqual(timeout.connect, 15)
            self.assertIsNone(timeout.read)
            self.assertEqual(timeout.write, 60)
            self.assertEqual(timeout.pool, 60)
            model_info = get_model_info(
                f"{LLAMACPP_UNBOUNDED_PROVIDER}/qwen3.8-27b-uncensored-q6"
            )
            self.assertEqual(model_info.context_length, 262_144)
        finally:
            await model.api.aclose()

    async def test_provider_rejects_a_conflicting_timeout_override(self) -> None:
        with self.assertRaisesRegex(ValueError, "must not be supplied"):
            get_model(
                f"{LLAMACPP_UNBOUNDED_PROVIDER}/contract-test",
                base_url="http://127.0.0.1:1/v1",
                api_key="unit-test-only",
                memoize=False,
                client_timeout=600,
            )


class InteractiveHarnessContractTests(unittest.TestCase):
    def test_benchmark_remains_default_and_interactive_is_opt_in(self) -> None:
        signature = inspect.signature(cybench_isolated)
        self.assertEqual(
            signature.parameters["runtime_mode"].default,
            RUNTIME_MODE_BENCHMARK,
        )
        self.assertEqual(RUNTIME_MODE_INTERACTIVE, "unbounded-interactive-v1")

        adapter = source("evals/cybench.py")
        self.assertIn(
            "[] if unbounded else [time_limit(solve_time_limit_seconds)]",
            adapter,
        )
        self.assertIn("bash(timeout=None if unbounded else 180)", adapter)
        self.assertIn("python(timeout=None if unbounded else 180)", adapter)
        self.assertIn("maxsize\n                    if unbounded", adapter)

    def test_benchmark_validation_is_unchanged_but_interactive_has_no_phase_deadline(
        self,
    ) -> None:
        async def passthrough(state, generate):
            return state

        with self.assertRaisesRegex(ValueError, "at least 7200"):
            solve_then_document(
                passthrough,
                solve_time_limit_seconds=1,
                documentation_time_limit_seconds=1,
                runtime_mode=RUNTIME_MODE_BENCHMARK,
            )
        # Construction succeeds with the same deliberately tiny values because
        # interactive-v1 never installs either phase timer.
        solve_then_document(
            passthrough,
            solve_time_limit_seconds=1,
            documentation_time_limit_seconds=1,
            runtime_mode=RUNTIME_MODE_INTERACTIVE,
        )

    def test_wrapper_separates_scored_benchmark_from_unbounded_agent_run(self) -> None:
        wrapper = source("scripts/run-cybench.sh")
        self.assertIn('runtime_mode="benchmark-v1"', wrapper)
        self.assertIn('model_provider="openai-api/llamacpp"', wrapper)
        self.assertIn('model_provider="llamacpp-unbounded-v1"', wrapper)
        self.assertIn(
            'unbounded-interactive-v1 is deliberately unscored',
            wrapper,
        )
        self.assertIn('sample_time_limit_args=()', wrapper)
        self.assertIn(
            'sample_time_limit_args=(--time-limit "${sample_time_limit_seconds}")',
            wrapper,
        )
        self.assertIn('model_client_timeout_args=()', wrapper)
        self.assertIn(
            '-M "client_timeout=${model_api_client_timeout_seconds}"',
            wrapper,
        )
        self.assertIn('main_generation_limit="physical_context_only"', wrapper)


class OpenCodeInteractiveContractTests(unittest.TestCase):
    def test_q6_chat_alias_has_context_reserve_and_keeps_eval_alias(self) -> None:
        config = parse_jsonc(source("opencode.jsonc"))
        self.assertEqual(config["model"], "runpod/uncensored-q6-interactive-v1")
        providers = config["providers"]
        self.assertIsInstance(providers, dict)
        models = providers["runpod"]["models"]
        interactive = models["uncensored-q6-interactive-v1"]
        evaluation = models["uncensored-q6"]
        self.assertEqual(interactive["modelID"], evaluation["modelID"])
        self.assertEqual(interactive["limit"]["context"], 262_144)
        self.assertEqual(interactive["limit"]["output"], 32_000)
        self.assertEqual(evaluation["limit"]["output"], 8_192)

    def test_runtime_generator_selects_interactive_q6_only_for_chat(self) -> None:
        generator = source("scripts/runpod-gui.ps1")
        common = source("scripts/RunPod.Common.psm1")
        self.assertIn("Write-OpenCodeRuntimeConfig", generator)
        self.assertIn("'uncensored-q6-interactive-v1'", common)
        self.assertIn('model = "runpod/$activeOpenCodeModel"', common)
        self.assertIn("OpenCodeModel", generator)
        self.assertIn(
            "disabled = ($activeOpenCodeModel -ne $interactiveOpenCodeModel)",
            common,
        )

    def test_alternative_profiles_disable_q6_interactive_after_deep_merge(self) -> None:
        powershell = (
            shutil.which("pwsh")
            or shutil.which("powershell.exe")
            or shutil.which("powershell")
        )
        if powershell is None:
            self.skipTest("PowerShell is required for runtime-config behavior")

        module_path = (PROJECT_ROOT / "scripts" / "RunPod.Common.psm1").resolve()
        module_argument = str(module_path)
        if powershell.lower().endswith(".exe"):
            posix_module = module_path.as_posix()
            if posix_module.startswith("/mnt/"):
                module_argument = (
                    f"{posix_module[5].upper()}:\\"
                    + posix_module[7:].replace("/", "\\")
                )
        for active_model in ("uncensored-q8", "uncensored-q4", "whitehat-q4"):
            harness = f"""
Set-StrictMode -Version Latest
Import-Module '{module_argument}' -Force
try {{
  $result = Write-OpenCodeRuntimeConfig -ActiveModel '{active_model}'
  $result.Config.providers.runpod.models | ConvertTo-Json -Depth 5 -Compress
}}
finally {{
  [void](Write-OpenCodeRuntimeConfig -ActiveModel 'uncensored-q6')
}}
"""
            with tempfile.TemporaryDirectory(dir=PROJECT_ROOT) as temporary:
                script = Path(temporary) / "opencode-runtime-contract.ps1"
                script.write_text(harness, encoding="utf-8")
                script_argument = str(script)
                if powershell.lower().endswith(".exe"):
                    posix = script.resolve().as_posix()
                    if posix.startswith("/mnt/"):
                        script_argument = (
                            f"{posix[5].upper()}:\\"
                            + posix[7:].replace("/", "\\")
                        )
                result = subprocess.run(
                    [
                        powershell,
                        "-NoLogo",
                        "-NoProfile",
                        "-NonInteractive",
                        "-File",
                        script_argument,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=30,
                    check=False,
                )
            self.assertEqual(result.returncode, 0, result.stderr)
            overrides = json.loads(result.stdout)
            self.assertFalse(overrides[active_model]["disabled"])
            self.assertTrue(
                overrides["uncensored-q6-interactive-v1"]["disabled"]
            )

    def test_long_idle_transport_guards_preserve_short_health_probes(self) -> None:
        gateway = source("agent/gateway-entrypoint.sh")
        ui_proxy = source("agent/ui-proxy.conf")
        compose = source("agent/compose.yaml")
        for proxy in (gateway, ui_proxy):
            self.assertIn("proxy_read_timeout 7d;", proxy)
            self.assertIn("proxy_send_timeout 7d;", proxy)
            self.assertNotIn("proxy_read_timeout 3600s;", proxy)
        self.assertIn("proxy_connect_timeout 15s;", gateway)
        self.assertIn('curl", "--fail", "--silent", "--show-error", "--max-time", "5"', compose)
        self.assertIn("qwen-eval.runtime-mode: unbounded-interactive-v1", compose)


class FinalHealthImportContractTests(unittest.TestCase):
    def test_productive_worker_sets_workdir_and_pythonpath(self) -> None:
        worker = source("scripts/cybench-supervisor-worker.ps1")
        final_health = worker[
            worker.index("function Invoke-FinalHealth") : worker.index(
                "function Set-Blocked"
            )
        ]
        self.assertIn(
            "$wslProjectRoot = ConvertTo-WslPath -WindowsPath $projectRoot",
            final_health,
        )
        self.assertIn("'/usr/bin/env', \"PYTHONPATH=$wslProjectRoot\"", final_health)
        self.assertIn("--cd $projectRoot -- @boundedHealthArguments", final_health)

    def test_health_cli_imports_from_an_unrelated_working_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            environment = os.environ.copy()
            environment["PYTHONPATH"] = str(PROJECT_ROOT)
            result = subprocess.run(
                [
                    sys.executable,
                    str(PROJECT_ROOT / "scripts" / "cybench_run_health.py"),
                    "--help",
                ],
                cwd=temporary_directory,
                env=environment,
                capture_output=True,
                text=True,
                # Importing Inspect Evals from the Windows-backed project can
                # take roughly 35-40 seconds on a cold WSL filesystem. This
                # timeout only bounds the regression subprocess; it is not a
                # model, agent, tool, or production health deadline.
                timeout=90,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--expected-model", result.stdout)


if __name__ == "__main__":
    unittest.main()

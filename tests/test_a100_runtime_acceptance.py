from __future__ import annotations

import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = PROJECT_ROOT / "scripts" / "runpod-a100-acceptance.ps1"
MODEL_MANIFEST_PATH = PROJECT_ROOT / "config" / "models.json"
DEPLOYMENT_MANIFEST_PATH = (
    PROJECT_ROOT / "config" / "runpod-a100-pcie-deployment.json"
)
DEPLOYMENT_VALIDATOR_PATH = (
    PROJECT_ROOT / "scripts" / "validate_runpod_deployment_manifest.py"
)
RUNTIME_GATE_PATH = PROJECT_ROOT / "runpod" / "runtime-gate.sh"


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def powershell_path(path: Path) -> str:
    resolved = path.resolve()
    if os.name == "nt":
        return str(resolved)
    posix = resolved.as_posix()
    match = re.fullmatch(r"/mnt/([a-zA-Z])/(.*)", posix)
    if match is None:
        return posix
    return f"{match.group(1).upper()}:\\" + match.group(2).replace("/", "\\")


def powershell_executable() -> str | None:
    return (
        shutil.which("pwsh")
        or shutil.which("powershell.exe")
        or shutil.which("powershell")
    )


def host_path_from_powershell(value: str) -> Path:
    if os.name == "nt":
        return Path(value)
    match = re.fullmatch(r"([a-zA-Z]):\\(.*)", value)
    if match is None:
        return Path(value)
    tail = match.group(2).replace("\\", "/")
    return Path(f"/mnt/{match.group(1).lower()}/{tail}")


def build_contract_fixture_project(root: Path) -> Path:
    """Render a canonical plan without relying on ignored repository state."""
    copies = (
        (MODEL_MANIFEST_PATH, root / "config" / "models.json"),
        (
            DEPLOYMENT_MANIFEST_PATH,
            root / "config" / "runpod-a100-pcie-deployment.json",
        ),
        (
            DEPLOYMENT_VALIDATOR_PATH,
            root / "scripts" / "validate_runpod_deployment_manifest.py",
        ),
        (PROJECT_ROOT / "evals" / "cybench.py", root / "evals" / "cybench.py"),
        (PROJECT_ROOT / "opencode.jsonc", root / "opencode.jsonc"),
    )
    for source, destination in copies:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

    plan_path = (
        root
        / ".runpod"
        / "deployments"
        / "a100-pcie-80gb-q6-v1"
        / "plan.json"
    )
    result = subprocess.run(
        [
            sys.executable,
            "-B",
            str(root / "scripts" / "validate_runpod_deployment_manifest.py"),
            "--manifest",
            str(root / "config" / "runpod-a100-pcie-deployment.json"),
            "--plan-output",
            str(plan_path),
            "--quiet",
        ],
        cwd=root,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "Failed to render the isolated acceptance plan fixture: "
            + result.stderr.strip()
        )
    if not plan_path.is_file():
        raise RuntimeError("Acceptance plan fixture was not rendered")
    return plan_path


def fixture(plan_sha256: str) -> dict[str, object]:
    manifest = json.loads(MODEL_MANIFEST_PATH.read_text(encoding="utf-8"))
    deployment = json.loads(DEPLOYMENT_MANIFEST_PATH.read_text(encoding="utf-8"))
    model = next(item for item in manifest["models"] if item["id"] == "uncensored-q6")
    alias = model["alias"]
    build = manifest["llama_cpp"]["expected_build_info"]
    return {
        "session": {
            "ActiveModel": "uncensored-q6",
            "ActiveAlias": alias,
            "RemoteDir": "/workspace/qwen-eval",
            "LlamaBuildInfo": build,
            "DeploymentId": deployment["deployment_id"],
            "DeploymentProfileId": deployment["deployment_profile_id"],
            "DeploymentPlanSha256": plan_sha256,
            "GpuName": "NVIDIA A100 80GB PCIe",
            "GpuCount": 1,
            "GpuMemoryMiB": 81100,
            "ComputeCapability": "8.0",
            "CudaRelease": "12.4",
        },
        "models": {"object": "list", "data": [{"id": alias, "object": "model"}]},
        "props": {
            "model_alias": alias,
            "model_ftype": "Q6_K",
            "model_path": (
                "/workspace/qwen-eval/models/uncensored-q6/"
                "Qwen3.8-27B-Uncensored-Q6_K.gguf"
            ),
            "build_info": build,
            "default_generation_settings": {"n_ctx": 262_144},
        },
        "chat": {
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": "A100_OK"},
                    "finish_reason": "stop",
                }
            ],
            "usage": {
                "prompt_tokens": 29,
                "completion_tokens": 4,
                "total_tokens": 33,
            },
            "timings": {
                "prompt_n": 29,
                "prompt_ms": 95.5,
                "prompt_per_second": 303.66,
                "predicted_n": 4,
                "predicted_ms": 160.0,
                "predicted_per_second": 25.0,
            },
        },
        "runtime_gate": [
            json.dumps(
                {
                    "schema_version": 1,
                    "process_memory_mib": 32768,
                    "server_binary_exact": True,
                    "host_loopback_exact": True,
                    "api_key_file_exact": True,
                    "no_ui_exact": True,
                    "context_size_exact": True,
                    "api_only_build_profile_exact": True,
                    "full_gpu_offload": True,
                },
                separators=(",", ":"),
            )
        ],
        "gpu_telemetry": ["NVIDIA A100 80GB PCIe, 81100, 33024, 48076"],
    }


@unittest.skipUnless(powershell_executable(), "PowerShell is required")
class A100RuntimeAcceptanceBehaviorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        # Keep the fixture on the shared Windows/WSL project mount. The WSL
        # suite intentionally invokes Windows PowerShell, which cannot resolve
        # a private WSL /tmp path.
        cls.contract_temporary = tempfile.TemporaryDirectory(dir=PROJECT_ROOT)
        cls.contract_root = Path(cls.contract_temporary.name) / "contract"
        cls.canonical_plan_path = build_contract_fixture_project(cls.contract_root)
        cls.canonical_plan_sha256 = sha256_file(cls.canonical_plan_path)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.contract_temporary.cleanup()

    def run_harness(
        self, root: Path, body: str
    ) -> subprocess.CompletedProcess[str]:
        executable = powershell_executable()
        assert executable is not None
        harness = root / "acceptance-harness.ps1"
        harness.write_text(
            textwrap.dedent(
                f"""
                Set-StrictMode -Version Latest
                $ErrorActionPreference = 'Stop'
                . '{powershell_path(SCRIPT_PATH)}'
                function Get-QwenProjectRoot {{
                    return '{powershell_path(self.contract_root)}'
                }}
                $fixture = Get-Content -LiteralPath '{powershell_path(root / 'fixture.json')}' -Raw -Encoding utf8 | ConvertFrom-Json
                $manifest = Get-Content -LiteralPath '{powershell_path(self.contract_root / 'config' / 'models.json')}' -Raw -Encoding utf8 | ConvertFrom-Json
                $model = @($manifest.models | Where-Object {{ $_.id -eq 'uncensored-q6' }})[0]
                {body}
                """
            ).lstrip(),
            encoding="utf-8",
        )
        return subprocess.run(
            [
                executable,
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                powershell_path(harness),
            ],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    def test_fixture_contract_writes_sanitized_machine_readable_pass_report(self) -> None:
        with tempfile.TemporaryDirectory(dir=PROJECT_ROOT) as temporary:
            root = Path(temporary)
            (root / "fixture.json").write_text(
                json.dumps(fixture(self.canonical_plan_sha256)), encoding="utf-8"
            )
            output = root / "reports"
            result = self.run_harness(
                root,
                f"""
                $binding = Get-A100DeploymentBindingEvidence -ProjectRoot '{powershell_path(self.contract_root)}' -Session $fixture.session
                $authentication = Assert-A100UnauthenticatedStatusCode -StatusCode 401
                $endpoint = Assert-A100RuntimeEndpointContract -Session $fixture.session -Manifest $manifest -Model $model -ModelsResponse $fixture.models -PropsResponse $fixture.props
                $gpu = ConvertFrom-A100GpuEvidence -Session $fixture.session -RuntimeGateOutput @($fixture.runtime_gate) -GpuTelemetryOutput @($fixture.gpu_telemetry)
                $first = ConvertTo-A100ChatAttempt -Response $fixture.chat -WallTimeMilliseconds 260 -AttemptNumber 1
                $second = ConvertTo-A100ChatAttempt -Response $fixture.chat -WallTimeMilliseconds 140 -AttemptNumber 2
                $attempts = @($first, $second)
                $determinism = Assert-A100ChatDeterminism -Attempts $attempts
                $report = New-A100AcceptanceReport -Session $fixture.session -Manifest $manifest -Model $model -DeploymentBindingEvidence $binding -AuthenticationEvidence $authentication -EndpointEvidence $endpoint -GpuEvidence $gpu -ChatAttempts $attempts -DeterminismEvidence $determinism -TotalWallMilliseconds 450
                $path = Write-A100AcceptanceReport -Report $report -Directory '{powershell_path(output)}' -KnownSecrets @('fixture-secret-never-write')
                Write-Output $path
                """,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            report_path = host_path_from_powershell(
                result.stdout.strip().splitlines()[-1]
            )
            self.assertTrue(report_path.is_file())
            raw = report_path.read_text(encoding="utf-8")
            report = json.loads(raw)

        self.assertEqual(report["schema_version"], 1)
        self.assertEqual(report["gate_id"], "a100-runtime-acceptance-v1")
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["runtime_contract"]["model"]["id"], "uncensored-q6")
        self.assertEqual(report["runtime_contract"]["model"]["context_tokens"], 262_144)
        self.assertEqual(
            report["checks"]["endpoint_identity"]["llama_build_info"],
            "b1-bb4caa754",
        )
        self.assertTrue(report["checks"]["endpoint_identity"]["q6_only"])
        binding = report["checks"]["qualified_session"]["deployment_binding"]
        self.assertTrue(binding["verified"])
        self.assertEqual(
            binding["deployment_manifest_sha256"],
            sha256_file(DEPLOYMENT_MANIFEST_PATH),
        )
        self.assertEqual(
            binding["canonical_plan_sha256"], self.canonical_plan_sha256
        )
        self.assertEqual(
            binding["rendered_plan_sha256"], self.canonical_plan_sha256
        )
        self.assertEqual(
            binding["model_manifest_sha256"], sha256_file(MODEL_MANIFEST_PATH)
        )
        self.assertTrue(
            report["checks"]["endpoint_authentication"][
                "unauthenticated_models_request_rejected"
            ]
        )
        self.assertEqual(
            report["checks"]["endpoint_authentication"]["status_code"], 401
        )
        process = report["checks"]["server_process"]
        self.assertTrue(process["pinned_server_binary"])
        self.assertTrue(process["host_loopback"])
        self.assertTrue(process["key_file_enabled"])
        self.assertTrue(process["web_ui_disabled"])
        self.assertTrue(process["context_262144_exact"])
        self.assertTrue(process["api_only_build_profile"])
        self.assertTrue(process["full_gpu_offload"])
        self.assertTrue(process["argv_verified_from_proc"])
        self.assertTrue(report["checks"]["gpu"]["full_gpu_offload"])
        self.assertEqual(report["checks"]["gpu"]["process_memory_used_mib"], 32_768)
        self.assertTrue(report["checks"]["deterministic_chat"]["verified"])
        self.assertEqual(report["chat_probe"]["aggregate"]["usage"]["total_tokens"], 66)
        self.assertEqual(report["chat_probe"]["aggregate"]["wall_milliseconds"], 400)
        self.assertEqual(report["timing"]["total_gate_wall_milliseconds"], 450)
        self.assertFalse(
            report["chat_probe"]["aggregate"]["performance_threshold_applied"]
        )
        self.assertNotIn("fixture-secret-never-write", raw)
        self.assertNotRegex(raw, re.compile(r"authorization|bearer|api[_-]?key", re.I))

    def test_contract_rejects_wrong_runtime_and_secret_bearing_report(self) -> None:
        with tempfile.TemporaryDirectory(dir=PROJECT_ROOT) as temporary:
            root = Path(temporary)
            (root / "fixture.json").write_text(
                json.dumps(fixture(self.canonical_plan_sha256)), encoding="utf-8"
            )
            result = self.run_harness(
                root,
                f"""
                $rejections = 0
                $deploymentManifest = Get-Content -LiteralPath '{powershell_path(self.contract_root / 'config' / 'runpod-a100-pcie-deployment.json')}' -Raw -Encoding utf8 | ConvertFrom-Json
                $canonicalPlan = Get-Content -LiteralPath '{powershell_path(self.canonical_plan_path)}' -Raw -Encoding utf8 | ConvertFrom-Json
                $deploymentManifestSha = Get-A100FileSha256 -Path '{powershell_path(self.contract_root / 'config' / 'runpod-a100-pcie-deployment.json')}'
                $canonicalPlanSha = Get-A100FileSha256 -Path '{powershell_path(self.canonical_plan_path)}'
                $modelManifestSha = Get-A100FileSha256 -Path '{powershell_path(self.contract_root / 'config' / 'models.json')}'
                $validBinding = Assert-A100DeploymentBindingContract -Session $fixture.session -DeploymentManifest $deploymentManifest -CanonicalPlan $canonicalPlan -DeploymentManifestSha256 $deploymentManifestSha -CanonicalPlanSha256 $canonicalPlanSha -RenderedPlanSha256 $canonicalPlanSha -ModelManifestSha256 $modelManifestSha

                $forgedReportBinding = $validBinding | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                $forgedReportBinding.deployment_manifest_sha256 = ('b' * 64)
                try {{ Assert-A100DeploymentBindingEvidenceForReport -Session $fixture.session -Evidence $forgedReportBinding | Out-Null }} catch {{ $rejections += 1 }}

                $badDeploymentSession = $fixture.session | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                $badDeploymentSession.DeploymentId = 'a100-pcie-wrong-witness'
                try {{ Assert-A100DeploymentBindingContract -Session $badDeploymentSession -DeploymentManifest $deploymentManifest -CanonicalPlan $canonicalPlan -DeploymentManifestSha256 $deploymentManifestSha -CanonicalPlanSha256 $canonicalPlanSha -RenderedPlanSha256 $canonicalPlanSha -ModelManifestSha256 $modelManifestSha | Out-Null }} catch {{ $rejections += 1 }}

                $badProfileSession = $fixture.session | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                $badProfileSession.DeploymentProfileId = 'a100-pcie-wrong-profile'
                try {{ Assert-A100DeploymentBindingContract -Session $badProfileSession -DeploymentManifest $deploymentManifest -CanonicalPlan $canonicalPlan -DeploymentManifestSha256 $deploymentManifestSha -CanonicalPlanSha256 $canonicalPlanSha -RenderedPlanSha256 $canonicalPlanSha -ModelManifestSha256 $modelManifestSha | Out-Null }} catch {{ $rejections += 1 }}

                $badPlanSession = $fixture.session | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                $badPlanSession.DeploymentPlanSha256 = ('b' * 64)
                try {{ Assert-A100DeploymentBindingContract -Session $badPlanSession -DeploymentManifest $deploymentManifest -CanonicalPlan $canonicalPlan -DeploymentManifestSha256 $deploymentManifestSha -CanonicalPlanSha256 $canonicalPlanSha -RenderedPlanSha256 $canonicalPlanSha -ModelManifestSha256 $modelManifestSha | Out-Null }} catch {{ $rejections += 1 }}

                $badDeploymentManifest = $deploymentManifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                $badDeploymentManifest.workload.model_manifest_sha256 = ('b' * 64)
                try {{ Assert-A100DeploymentBindingContract -Session $fixture.session -DeploymentManifest $badDeploymentManifest -CanonicalPlan $canonicalPlan -DeploymentManifestSha256 $deploymentManifestSha -CanonicalPlanSha256 $canonicalPlanSha -RenderedPlanSha256 $canonicalPlanSha -ModelManifestSha256 $modelManifestSha | Out-Null }} catch {{ $rejections += 1 }}

                $badCanonicalPlan = $canonicalPlan | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                $badCanonicalPlan.target.pod_name = 'a100-pcie-wrong-witness'
                try {{ Assert-A100DeploymentBindingContract -Session $fixture.session -DeploymentManifest $deploymentManifest -CanonicalPlan $badCanonicalPlan -DeploymentManifestSha256 $deploymentManifestSha -CanonicalPlanSha256 $canonicalPlanSha -RenderedPlanSha256 $canonicalPlanSha -ModelManifestSha256 $modelManifestSha | Out-Null }} catch {{ $rejections += 1 }}

                $badModels = $fixture.models | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                $badModels.data = @($badModels.data, [pscustomobject]@{{ id = 'qwen3.8-27b-uncensored-q8' }})
                try {{ Assert-A100RuntimeEndpointContract -Session $fixture.session -Manifest $manifest -Model $model -ModelsResponse $badModels -PropsResponse $fixture.props | Out-Null }} catch {{ $rejections += 1 }}

                $badProps = $fixture.props | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                $badProps.default_generation_settings.n_ctx = 65536
                try {{ Assert-A100RuntimeEndpointContract -Session $fixture.session -Manifest $manifest -Model $model -ModelsResponse $fixture.models -PropsResponse $badProps | Out-Null }} catch {{ $rejections += 1 }}

                $badBuild = $fixture.props | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                $badBuild.build_info = 'wrong-build'
                try {{ Assert-A100RuntimeEndpointContract -Session $fixture.session -Manifest $manifest -Model $model -ModelsResponse $fixture.models -PropsResponse $badBuild | Out-Null }} catch {{ $rejections += 1 }}

                $badChat = $fixture.chat | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                $badChat.choices[0].message.content = 'NOT_OK'
                try {{ ConvertTo-A100ChatAttempt -Response $badChat -WallTimeMilliseconds 1 -AttemptNumber 1 | Out-Null }} catch {{ $rejections += 1 }}

                $lowMemoryRuntime = [string]$fixture.runtime_gate[0] | ConvertFrom-Json
                $lowMemoryRuntime.process_memory_mib = 29999
                try {{ ConvertFrom-A100GpuEvidence -Session $fixture.session -RuntimeGateOutput @(($lowMemoryRuntime | ConvertTo-Json -Compress)) -GpuTelemetryOutput @($fixture.gpu_telemetry) | Out-Null }} catch {{ $rejections += 1 }}

                $unsafeRuntime = [string]$fixture.runtime_gate[0] | ConvertFrom-Json
                $unsafeRuntime.host_loopback_exact = $false
                try {{ ConvertFrom-A100GpuEvidence -Session $fixture.session -RuntimeGateOutput @(($unsafeRuntime | ConvertTo-Json -Compress)) -GpuTelemetryOutput @($fixture.gpu_telemetry) | Out-Null }} catch {{ $rejections += 1 }}

                try {{ ConvertFrom-A100GpuEvidence -Session $fixture.session -RuntimeGateOutput @('not-json') -GpuTelemetryOutput @($fixture.gpu_telemetry) | Out-Null }} catch {{ $rejections += 1 }}

                try {{ Assert-A100UnauthenticatedStatusCode -StatusCode 200 | Out-Null }} catch {{ $rejections += 1 }}

                try {{ Invoke-A100LocalJsonRequest -Uri 'https://example.invalid/v1/models' -Headers @{{ Authorization = 'Bearer fixture-secret-never-write' }} -RequestName models | Out-Null }} catch {{ $rejections += 1 }}

                $unsafeReport = [pscustomobject]@{{ status = 'passed'; accidental = 'fixture-secret-never-write' }}
                try {{ Write-A100AcceptanceReport -Report $unsafeReport -Directory '{powershell_path(root / 'unsafe')}' -KnownSecrets @('fixture-secret-never-write') | Out-Null }} catch {{ $rejections += 1 }}

                if ($rejections -ne 16) {{ throw "Expected sixteen fail-closed rejections, received $rejections." }}
                Write-Output 'REJECTIONS_OK'
                """,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("REJECTIONS_OK", result.stdout)

    def test_unauthenticated_probe_requires_real_loopback_401_or_403(self) -> None:
        class FixedStatusHandler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - stdlib callback name
                self.server.seen_auth.append(self.headers.get("Authorization"))
                self.send_response(self.server.response_status)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, _format: str, *args: object) -> None:
                return

        for status_code, should_pass in ((401, True), (403, True), (200, False)):
            server = ThreadingHTTPServer(("127.0.0.1", 0), FixedStatusHandler)
            server.response_status = status_code
            server.seen_auth = []
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with tempfile.TemporaryDirectory(dir=PROJECT_ROOT) as temporary:
                    root = Path(temporary)
                    (root / "fixture.json").write_text(
                        json.dumps(fixture(self.canonical_plan_sha256)),
                        encoding="utf-8",
                    )
                    port = server.server_address[1]
                    if should_pass:
                        body = f"""
                        $evidence = Invoke-A100UnauthenticatedAuthProbe -Uri 'http://127.0.0.1:{port}/v1/models' -TimeoutSeconds 10
                        if (-not $evidence.verified -or [int]$evidence.status_code -ne {status_code}) {{ throw 'Authentication rejection evidence mismatch.' }}
                        Write-Output 'AUTH_PROBE_OK'
                        """
                        expected = "AUTH_PROBE_OK"
                    else:
                        body = f"""
                        try {{
                            Invoke-A100UnauthenticatedAuthProbe -Uri 'http://127.0.0.1:{port}/v1/models' -TimeoutSeconds 10 | Out-Null
                            throw 'HTTP 200 was incorrectly accepted.'
                        }}
                        catch {{
                            if ($_.Exception.Message -eq 'HTTP 200 was incorrectly accepted.') {{ throw }}
                            Write-Output 'AUTH_PROBE_REJECTED'
                        }}
                        """
                        expected = "AUTH_PROBE_REJECTED"
                    result = self.run_harness(root, body)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected, result.stdout)
                self.assertEqual(server.seen_auth, [None])
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)


class A100RuntimeAcceptanceDistributionTests(unittest.TestCase):
    def test_live_wrapper_uses_qualified_helpers_and_small_loopback_probe(self) -> None:
        source = SCRIPT_PATH.read_text(encoding="utf-8")
        for required in (
            "Get-RunPodSession",
            "Assert-RunPodQualifiedSession",
            "Get-A100DeploymentBindingEvidence",
            "Start-RunPodTunnel",
            "Save-RunPodSession",
            "Stop-RunPodTunnel",
            "Wait-RunPodLocalEndpoint",
            "Get-RunPodApiKey",
            "Invoke-RunPodSshBounded",
            "runtime-gate.sh",
            "Invoke-A100UnauthenticatedAuthProbe",
            "/v1/models",
            "/props",
            "/v1/chat/completions",
            "artifacts\\acceptance",
        ):
            self.assertIn(required, source)
        self.assertIn("$script:AcceptanceSeed = 424242", source)
        self.assertIn("$script:AcceptanceMaxTokens = 16", source)
        self.assertIn("temperature = 0", source)
        self.assertIn("enable_thinking = $false", source)
        self.assertIn("/no_think", source)
        self.assertIn("stream = $false", source)
        self.assertIn("performance_threshold_applied = $false", source)
        self.assertIn("config\\runpod-a100-pcie-deployment.json", source)
        self.assertIn("DeploymentPlanSha256", source)
        self.assertIn("canonical_plan_matches_validated_manifest", source)
        self.assertIn("deployment_manifest_sha256", source)
        self.assertIn("rendered_plan_sha256", source)
        self.assertLess(source.index("Start-RunPodTunnel"), source.index("Save-RunPodSession"))
        self.assertNotIn("runpod-gui.ps1", source)
        self.assertNotIn("Start-RunPodWslTunnel", source)

    def test_remote_gate_uses_nul_argv_and_exact_api_only_process_contract(self) -> None:
        source = RUNTIME_GATE_PATH.read_text(encoding="utf-8")
        self.assertIn('mapfile -d \'\' -t server_argv', source)
        self.assertIn('/proc/${pid}/cmdline', source)
        self.assertIn('require_exact_option_value --host 127.0.0.1', source)
        self.assertIn('require_exact_option_value --api-key-file "${api_key_file}"', source)
        self.assertIn('require_exact_option_value --n-gpu-layers 99', source)
        self.assertIn('require_exact_option_value --ctx-size 262144', source)
        self.assertIn('require_exact_flag --no-ui', source)
        self.assertIn('.build_profile == "api_only_v1"', source)
        self.assertNotIn('ps -p "${pid}" -o args=', source)

    def test_generated_reports_are_ignored(self) -> None:
        ignore = (PROJECT_ROOT / ".gitignore").read_text(encoding="utf-8")
        self.assertIn("artifacts/acceptance/*", ignore)


@unittest.skipUnless(
    os.name == "posix" and shutil.which("bash") and shutil.which("jq"),
    "requires POSIX bash, /proc, and jq",
)
class A100RuntimeGateBehaviorTests(unittest.TestCase):
    def test_gate_accepts_exact_argv_and_rejects_host_context_or_build_drift(self) -> None:
        with tempfile.TemporaryDirectory(dir=PROJECT_ROOT) as temporary:
            root = Path(temporary)
            state = root / "state"
            fake_bin = root / "bin"
            for directory in (state, fake_bin, root / "models", root / "logs", root / "cache"):
                directory.mkdir(parents=True, exist_ok=True)
            fake_server = root / "llama-server"
            fake_server.symlink_to("/bin/sh")
            nvidia_smi = fake_bin / "nvidia-smi"
            nvidia_smi.write_text(
                "#!/bin/sh\n"
                "pid=$(cat \"$QWEN_STATE_DIR/llama-server.pid\")\n"
                "printf '%s, 32768\\n' \"$pid\"\n",
                encoding="utf-8",
            )
            nvidia_smi.chmod(0o755)
            (state / "api-key").write_text("fixture-only", encoding="ascii")

            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
                    "QWEN_STATE_DIR": str(state),
                    "QWEN_MODELS_DIR": str(root / "models"),
                    "QWEN_LOGS_DIR": str(root / "logs"),
                    "QWEN_CACHE_DIR": str(root / "cache"),
                    "QWEN_LLAMA_SERVER_BIN": str(fake_server),
                }
            )

            def run_gate(host: str, context: str, build_profile: str) -> subprocess.CompletedProcess[str]:
                (state / "bootstrap.json").write_text(
                    json.dumps({"build_profile": build_profile}), encoding="utf-8"
                )
                process = subprocess.Popen(
                    [
                        str(fake_server),
                        "-c",
                        "trap ':' TERM; sleep 60 & wait",
                        "qwen-runtime-gate",
                        "--host",
                        host,
                        "--api-key-file",
                        str(state / "api-key"),
                        "--n-gpu-layers",
                        "99",
                        "--ctx-size",
                        context,
                        "--no-ui",
                    ],
                    executable="/bin/sh",
                    env=environment,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                try:
                    (state / "llama-server.pid").write_text(
                        f"{process.pid}\n", encoding="ascii"
                    )
                    return subprocess.run(
                        ["bash", str(RUNTIME_GATE_PATH), "30000"],
                        cwd=PROJECT_ROOT,
                        env=environment,
                        capture_output=True,
                        text=True,
                        timeout=15,
                        check=False,
                    )
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=3)

            accepted = run_gate("127.0.0.1", "262144", "api_only_v1")
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            evidence = json.loads(accepted.stdout)
            self.assertEqual(evidence["process_memory_mib"], 32768)
            self.assertTrue(evidence["host_loopback_exact"])
            self.assertTrue(evidence["context_size_exact"])
            self.assertTrue(evidence["api_only_build_profile_exact"])

            for host, context, profile in (
                ("0.0.0.0", "262144", "api_only_v1"),
                ("127.0.0.1", "65536", "api_only_v1"),
                ("127.0.0.1", "262144", "mutable_ui"),
            ):
                with self.subTest(host=host, context=context, profile=profile):
                    rejected = run_gate(host, context, profile)
                    self.assertNotEqual(rejected.returncode, 0)


if __name__ == "__main__":
    unittest.main()

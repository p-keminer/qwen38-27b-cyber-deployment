from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
MODEL_MANIFEST_PATH = PROJECT_ROOT / "config" / "models.json"
DEPLOYMENT_MANIFEST_PATH = (
    PROJECT_ROOT / "config" / "runpod-a100-pcie-deployment.json"
)


def source(relative_path: str) -> str:
    return (PROJECT_ROOT / relative_path).read_text(encoding="utf-8")


def load_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def powershell_path(path: Path) -> str:
    """Return a path Windows PowerShell can consume from Windows or WSL."""

    resolved = path.resolve()
    if os.name == "nt":
        return str(resolved)
    posix = resolved.as_posix()
    match = re.fullmatch(r"/mnt/([a-zA-Z])/(.*)", posix)
    if match is None:
        return posix
    return f"{match.group(1).upper()}:\\" + match.group(2).replace("/", "\\")


def wsl_path(path: Path) -> str:
    """Return a path the configured WSL distribution can consume."""

    resolved = path.resolve()
    if os.name != "nt":
        return resolved.as_posix()
    drive = resolved.drive.rstrip(":").lower()
    relative = resolved.as_posix().split(":/", 1)[1]
    return f"/mnt/{drive}/{relative}"


class A100ManifestContractTests(unittest.TestCase):
    def test_manifest_pins_old_a40_llamacpp_build_identity(self) -> None:
        manifest = load_json(MODEL_MANIFEST_PATH)
        llama_cpp = manifest["llama_cpp"]
        self.assertEqual(llama_cpp["revision"], "v0.2.0")
        self.assertEqual(llama_cpp["expected_commit_prefix"], "bb4caa754")
        self.assertEqual(llama_cpp["expected_build_info"], "b1-bb4caa754")

        validator = source("scripts/validate_model_manifest.py")
        self.assertIn("expected_commit_prefix", validator)
        self.assertIn("expected_build_info", validator)
        self.assertIn('f"b1-{commit_prefix}"', validator)

    def test_q6_artifact_identity_does_not_change_with_hardware(self) -> None:
        manifest = load_json(MODEL_MANIFEST_PATH)
        models = {entry["id"]: entry for entry in manifest["models"]}
        q6 = models["uncensored-q6"]
        self.assertEqual(q6["revision"], "dee0a3164d9e11bbbebf5b63f52ba99443d14fc3")
        self.assertEqual(q6["expected_size_bytes"], 22_430_999_968)
        self.assertEqual(
            q6["sha256"],
            "a50aa1478295b58ee3d93eabe02c17f6d5fcf6cb787fd8a0ab07ac629a46cae6",
        )
        self.assertEqual(
            q6["vision_projector"]["sha256"],
            "5ac423f8a29059dc24e51bc6a43e9380dcd57a9347f28b62591e0b3f60b7081c",
        )
        self.assertEqual(q6["context_size"], 262_144)

    def test_deployment_manifest_binds_the_current_model_manifest(self) -> None:
        deployment = load_json(DEPLOYMENT_MANIFEST_PATH)
        expected = deployment["workload"]["model_manifest_sha256"]
        actual = hashlib.sha256(MODEL_MANIFEST_PATH.read_bytes()).hexdigest()
        self.assertEqual(expected, actual)


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires POSIX bash")
class A100HardwareGateBehaviorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(dir=PROJECT_ROOT)
        self.root = Path(self.temporary.name)
        self.fake_bin = self.root / "bin"
        self.workspace = self.root / "workspace"
        self.fake_bin.mkdir()
        self.workspace.mkdir()

        gate_source = source("runpod/hardware-gate.sh").replace(
            "/workspace", self.workspace.as_posix()
        )
        self.gate = self.root / "hardware-gate.sh"
        self.gate.write_text(gate_source, encoding="utf-8")

        self._write_executable(
            "nvidia-smi",
            """
            #!/usr/bin/env bash
            set -Eeuo pipefail
            case "$*" in
              *"--query-gpu=name,memory.total,compute_cap"*)
                printf '%b' "${FAKE_GPU_ROWS:?}"
                ;;
              *)
                echo "unexpected nvidia-smi arguments: $*" >&2
                exit 90
                ;;
            esac
            """,
        )
        self._write_executable(
            "nvcc",
            """
            #!/usr/bin/env bash
            printf 'Cuda compilation tools, release %s, V%s.0.0\n' \
              "${FAKE_CUDA_RELEASE:?}" "${FAKE_CUDA_RELEASE}"
            """,
        )
        self._write_executable(
            "findmnt",
            """
            #!/usr/bin/env bash
            printf '%s\n' "${FAKE_WORKSPACE:?}"
            """,
        )
        self._write_executable(
            "df",
            """
            #!/usr/bin/env bash
            case "$*" in
              *"--output=size"*) printf '1B-blocks\n120000000000\n' ;;
              *"--output=avail"*) printf 'Avail\n100000000000\n' ;;
              *) exit 91 ;;
            esac
            """,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_executable(self, name: str, body: str) -> None:
        path = self.fake_bin / name
        path.write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
        path.chmod(0o755)

    def _run_gate(
        self,
        *,
        gpu_rows: str | None = None,
        cuda_release: str = "12.4",
    ) -> subprocess.CompletedProcess[str]:
        deployment = load_json(DEPLOYMENT_MANIFEST_PATH)
        hardware = deployment["hardware"]
        container = deployment["container"]
        if gpu_rows is None:
            gpu_rows = f"{hardware['expected_gpu_name']}, 81100, 8.0\n"
        state_path = self.root / "state" / "hardware.json"
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{self.fake_bin}{os.pathsep}{environment['PATH']}",
                "FAKE_GPU_ROWS": gpu_rows,
                "FAKE_CUDA_RELEASE": cuda_release,
                "FAKE_WORKSPACE": self.workspace.as_posix(),
            }
        )
        return subprocess.run(
            [
                "bash",
                str(self.gate),
                str(hardware["expected_gpu_name"]),
                str(hardware["expected_compute_capability"]),
                str(container["expected_cuda_release"]),
                str(hardware["minimum_gpu_memory_mib"]),
                "80000000000",
                str(state_path),
            ],
            cwd=PROJECT_ROOT,
            env=environment,
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )

    def test_exact_single_a100_pcie_sm80_cuda124_and_workspace_pass(self) -> None:
        result = self._run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertTrue(record["qualified"])
        deployment = load_json(DEPLOYMENT_MANIFEST_PATH)
        self.assertEqual(
            record["gpu_name"], deployment["hardware"]["expected_gpu_name"]
        )
        self.assertEqual(record["gpu_count"], 1)
        self.assertEqual(record["compute_capability"], "8.0")
        self.assertEqual(record["cuda_release"], "12.4")
        self.assertEqual(record["workspace_mount"], self.workspace.as_posix())
        self.assertGreaterEqual(record["workspace_free_bytes"], 80_000_000_000)

    def test_wrong_gpu_count_name_compute_capability_or_cuda_is_rejected(self) -> None:
        expected_gpu = load_json(DEPLOYMENT_MANIFEST_PATH)["hardware"][
            "expected_gpu_name"
        ]
        cases = (
            (
                "two GPUs",
                {
                    "gpu_rows": (
                        f"{expected_gpu}, 81100, 8.0\n"
                        f"{expected_gpu}, 81100, 8.0\n"
                    )
                },
                "Expected exactly one GPU",
            ),
            (
                "A40",
                {"gpu_rows": "NVIDIA A40, 46068, 8.6\n"},
                "Unexpected GPU",
            ),
            (
                "wrong compute capability",
                {"gpu_rows": f"{expected_gpu}, 81100, 8.6\n"},
                "Unexpected compute capability",
            ),
            (
                "wrong CUDA",
                {"cuda_release": "12.3"},
                "Unexpected CUDA toolkit release",
            ),
        )
        for label, arguments, expected_error in cases:
            with self.subTest(label=label):
                result = self._run_gate(**arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected_error, result.stderr)


class A100BootstrapContractTests(unittest.TestCase):
    def test_bootstrap_resolves_pinned_commit_and_builds_only_sm80_cuda(self) -> None:
        bootstrap = source("runpod/bootstrap.sh")
        self.assertIn(
            "llama_expected_commit_prefix=\"$(manifest_value '.llama_cpp.expected_commit_prefix')\"",
            bootstrap,
        )
        self.assertIn(
            '[[ "${llama_resolved_revision}" == "${llama_expected_commit_prefix}"* ]]',
            bootstrap,
        )
        self.assertIn('-DCMAKE_CUDA_ARCHITECTURES="${cuda_architectures}"', bootstrap)
        self.assertIn("-DGGML_CUDA=ON", bootstrap)
        self.assertIn("^CMAKE_CUDA_ARCHITECTURES:[^=]+=80$", bootstrap)
        self.assertIn("^GGML_CUDA:BOOL=ON$", bootstrap)
        self.assertIn("--arg cuda_architectures", bootstrap)
        self.assertIn("--arg llama_cpp_revision", bootstrap)

    def test_bootstrap_builds_api_only_without_mutable_ui_assets(self) -> None:
        bootstrap = source("runpod/bootstrap.sh")
        cleanup = 'rm -rf -- "${ui_build_dir}/dist" "${ui_build_dir}/ui-src"'
        self.assertIn(cleanup, bootstrap)
        for artifact in (
            ".ui-stamp",
            "dist.tar.gz",
            "dist.tar.gz.sha256",
            "ui.cpp",
            "ui.h",
        ):
            self.assertIn(f'"${{ui_build_dir}}/{artifact}"', bootstrap)
        self.assertLess(bootstrap.index(cleanup), bootstrap.index("cmake -S"))
        self.assertIn("-DLLAMA_BUILD_UI=OFF", bootstrap)
        self.assertIn("-DLLAMA_USE_PREBUILT_UI=OFF", bootstrap)
        self.assertIn("^LLAMA_BUILD_UI:BOOL=OFF$", bootstrap)
        self.assertIn("^LLAMA_USE_PREBUILT_UI:BOOL=OFF$", bootstrap)
        self.assertIn('--arg build_profile "api_only_v1"', bootstrap)
        self.assertIn('build_profile:$build_profile', bootstrap)
        no_assets_gate = bootstrap[
            bootstrap.index('ui_header="${ui_build_dir}/ui.h"') :
            bootstrap.index('run_id="$(date -u')
        ]
        self.assertIn("if grep -Eq", no_assets_gate)
        self.assertIn("LLAMA_UI_HAS_ASSETS", no_assets_gate)
        self.assertIn("embedded Web UI assets in the API-only build", no_assets_gate)

    def test_bootstrap_pins_hugging_face_cli_without_remote_shell_pipe(self) -> None:
        bootstrap = source("runpod/bootstrap.sh")
        self.assertIn('hf_cli_version="1.28.0"', bootstrap)
        self.assertIn('"huggingface_hub==${hf_cli_version}"', bootstrap)
        self.assertIn("python3-pip", bootstrap)
        self.assertIn("--model-source", bootstrap)
        self.assertIn('export QWEN_MODEL_SOURCE="${model_source}"', bootstrap)
        self.assertIn('if [[ "${model_source}" != "local-only" ]]', bootstrap)
        self.assertIn('model_source:$model_source', bootstrap)
        self.assertNotIn("hf.co/cli/install.sh", bootstrap)
        self.assertNotIn("curl -LsSf", bootstrap)


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires POSIX bash")
class ModelShaBehaviorTests(unittest.TestCase):
    def test_modelctl_local_only_uses_valid_files_without_hf(self) -> None:
        with tempfile.TemporaryDirectory(dir=PROJECT_ROOT) as temporary:
            root = Path(temporary)
            model_bytes = b"local-only-model"
            projector_bytes = b"local-only-projector"
            manifest = {
                "models": [
                    {
                        "id": "mini-q6",
                        "repo_id": "owner/repo",
                        "revision": "a" * 40,
                        "filename": "mini.gguf",
                        "expected_size_bytes": len(model_bytes),
                        "sha256": hashlib.sha256(model_bytes).hexdigest(),
                        "vision_projector": {
                            "filename": "mini-mmproj.gguf",
                            "expected_size_bytes": len(projector_bytes),
                            "sha256": hashlib.sha256(projector_bytes).hexdigest(),
                        },
                    }
                ]
            }
            manifest_path = root / "models.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            model_dir = root / "models" / "mini-q6"
            model_dir.mkdir(parents=True)
            (model_dir / "mini.gguf").write_bytes(model_bytes)
            projector_path = model_dir / "mini-mmproj.gguf"
            projector_path.write_bytes(projector_bytes)

            marker = root / "hf-was-called"
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_hf = fake_bin / "hf"
            fake_hf.write_text(
                f"#!/usr/bin/env bash\ntouch '{marker}'\nexit 99\n",
                encoding="utf-8",
            )
            fake_hf.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
                    "QWEN_MODEL_SOURCE": "local-only",
                    "QWEN_MODEL_MANIFEST": str(manifest_path),
                    "QWEN_MODELS_DIR": str(root / "models"),
                    "QWEN_STATE_DIR": str(root / "state"),
                    "QWEN_LOGS_DIR": str(root / "logs"),
                    "QWEN_CACHE_DIR": str(root / "cache"),
                    "QWEN_LLAMA_SOURCE_DIR": str(root / "llama.cpp"),
                    "QWEN_LLAMA_SERVER_BIN": str(root / "llama-server"),
                }
            )
            command = [
                "bash",
                str(PROJECT_ROOT / "runpod" / "modelctl.sh"),
                "download",
                "mini-q6",
            ]
            valid = subprocess.run(
                command,
                cwd=PROJECT_ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
            )
            self.assertEqual(valid.returncode, 0, valid.stderr)
            self.assertFalse(marker.exists())
            metadata = json.loads((model_dir / "download.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["source"], "existing_local")

            projector_path.unlink()
            missing = subprocess.run(
                command,
                cwd=PROJECT_ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
            )
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("Local-only model source", missing.stderr)
            self.assertFalse(marker.exists())

    def test_modelctl_verify_rehashes_and_rejects_same_size_corruption(self) -> None:
        with tempfile.TemporaryDirectory(dir=PROJECT_ROOT) as temporary:
            root = Path(temporary)
            model_bytes = b"model-contract-payload"
            projector_bytes = b"projector-contract-payload"
            model_sha = hashlib.sha256(model_bytes).hexdigest()
            projector_sha = hashlib.sha256(projector_bytes).hexdigest()
            manifest = {
                "models": [
                    {
                        "id": "mini-q6",
                        "filename": "mini.gguf",
                        "expected_size_bytes": len(model_bytes),
                        "sha256": model_sha,
                        "vision_projector": {
                            "filename": "mini-mmproj.gguf",
                            "expected_size_bytes": len(projector_bytes),
                            "sha256": projector_sha,
                        },
                    }
                ]
            }
            manifest_path = root / "models.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            model_dir = root / "models" / "mini-q6"
            model_dir.mkdir(parents=True)
            model_path = model_dir / "mini.gguf"
            projector_path = model_dir / "mini-mmproj.gguf"
            model_path.write_bytes(model_bytes)
            projector_path.write_bytes(projector_bytes)

            environment = os.environ.copy()
            environment.update(
                {
                    "QWEN_MODEL_MANIFEST": str(manifest_path),
                    "QWEN_MODELS_DIR": str(root / "models"),
                    "QWEN_STATE_DIR": str(root / "state"),
                    "QWEN_LOGS_DIR": str(root / "logs"),
                    "QWEN_CACHE_DIR": str(root / "cache"),
                    "QWEN_LLAMA_SOURCE_DIR": str(root / "llama.cpp"),
                    "QWEN_LLAMA_SERVER_BIN": str(root / "llama-server"),
                }
            )
            command = [
                "bash",
                str(PROJECT_ROOT / "runpod" / "modelctl.sh"),
                "verify",
                "mini-q6",
            ]
            valid = subprocess.run(
                command,
                cwd=PROJECT_ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
            )
            self.assertEqual(valid.returncode, 0, valid.stderr)
            self.assertIn("SHA-256 verified", valid.stdout)

            model_path.write_bytes(b"X" + model_bytes[1:])
            corrupted = subprocess.run(
                command,
                cwd=PROJECT_ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
            )
            self.assertNotEqual(corrupted.returncode, 0)
            self.assertIn("Model SHA-256 mismatch", corrupted.stderr)


class ServerStartContractTests(unittest.TestCase):
    def test_server_download_rehashes_once_before_process_start(self) -> None:
        server = source("runpod/server-control.sh")
        start = server[server.index("start_server()") : server.index("status_server()")]
        download = start.index('modelctl.sh\" download')
        launch = start.index('nohup "${command[@]}"')
        self.assertLess(download, launch)
        self.assertNotIn('modelctl.sh\" verify', start)
        modelctl = source("runpod/modelctl.sh")
        download_model = modelctl[modelctl.index("download_model()") : modelctl.index("verify_model()")]
        self.assertGreaterEqual(download_model.count("sha256sum"), 2)
        self.assertIn("--ctx-size \"${context_size}\"", start)
        self.assertIn("--n-gpu-layers 99", start)
        self.assertIn("--no-ui", start)


class QualifiedSessionContractTests(unittest.TestCase):
    def test_common_requires_qualified_target_session_and_pinned_build(self) -> None:
        powershell = (
            shutil.which("pwsh")
            or shutil.which("powershell.exe")
            or shutil.which("powershell")
        )
        if powershell is None:
            self.skipTest("PowerShell is required for session behavior")

        deployment = load_json(DEPLOYMENT_MANIFEST_PATH)
        hardware = deployment["hardware"]
        container = deployment["container"]
        model_manifest = load_json(MODEL_MANIFEST_PATH)
        with tempfile.TemporaryDirectory(dir=PROJECT_ROOT) as temporary:
            root = Path(temporary)
            identity = root / "identity"
            identity.write_text("unit-test-only", encoding="ascii")
            harness = root / "qualified-session.ps1"
            harness.write_text(
                textwrap.dedent(
                    f"""
                    Set-StrictMode -Version Latest
                    $ErrorActionPreference = 'Stop'
                    Import-Module '{powershell_path(PROJECT_ROOT / 'scripts' / 'RunPod.Common.psm1')}' -Force
                    $session = [pscustomobject]@{{
                        SshHost = 'localhost'
                        SshPort = 22
                        SshUser = 'root'
                        IdentityFile = '{powershell_path(identity)}'
                        RemoteDir = '/workspace/qwen-eval'
                        PodId = 'abcdefgh1234'
                        DeploymentId = '{deployment['deployment_id']}'
                        DeploymentProfileId = '{deployment['deployment_profile_id']}'
                        DeploymentPlanSha256 = '{'a' * 64}'
                        LifecycleStatus = 'ready'
                        GpuName = '{hardware['expected_gpu_name']}'
                        GpuCount = {hardware['gpu_count']}
                        GpuMemoryMiB = {hardware['minimum_gpu_memory_mib']}
                        ComputeCapability = '{hardware['expected_compute_capability']}'
                        CudaRelease = '{container['expected_cuda_release']}'
                        LlamaBuildInfo = '{model_manifest['llama_cpp']['expected_build_info']}'
                    }}
                    Assert-RunPodQualifiedSession -Session $session
                    $session.GpuMemoryMiB = 79999
                    $memoryRejected = $false
                    try {{ Assert-RunPodQualifiedSession -Session $session }} catch {{ $memoryRejected = $true }}
                    if (-not $memoryRejected) {{ throw 'A sub-contract GPU memory value was accepted.' }}
                    $session.GpuMemoryMiB = {hardware['minimum_gpu_memory_mib']}
                    $session.LlamaBuildInfo = 'wrong-build'
                    $rejected = $false
                    try {{ Assert-RunPodQualifiedSession -Session $session }} catch {{ $rejected = $true }}
                    if (-not $rejected) {{ throw 'A mismatched llama.cpp build was accepted.' }}
                    Write-Output 'QUALIFIED_SESSION_OK'
                    """
                ).lstrip(),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    powershell,
                    "-NoLogo",
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    powershell_path(harness),
                ],
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("QUALIFIED_SESSION_OK", result.stdout)

    def test_endpoint_identity_binds_props_build_info_to_manifest(self) -> None:
        common = source("scripts/RunPod.Common.psm1")
        endpoint = common[
            common.index("function Assert-RunPodLocalEndpointIdentity") : common.index(
                "function Wait-RunPodLocalEndpoint"
            )
        ]
        self.assertIn("$Props.build_info", endpoint)
        self.assertIn("$manifest.llama_cpp.expected_build_info", endpoint)
        self.assertIn("$Props.model_ftype", endpoint)
        self.assertIn("$Props.default_generation_settings.n_ctx", endpoint)


class DeployOrderingContractTests(unittest.TestCase):
    def test_deploy_requires_binding_metadata_and_does_not_launch_gui_by_default(self) -> None:
        deploy = source("scripts/runpod-deploy.ps1")
        parameter_block = deploy[: deploy.index("Set-StrictMode")]
        for name in (
            "PodId",
            "DeploymentId",
            "DeploymentProfileId",
            "DeploymentPlanSha256",
            "ProvisioningStatePath",
            "ExpectedGpuName",
            "ExpectedGpuMemoryMiB",
            "ExpectedComputeCapability",
            "ExpectedCudaRelease",
        ):
            self.assertRegex(
                parameter_block,
                rf"\[Parameter\(Mandatory\)\][^\r\n]*\${name}\b",
            )
        self.assertRegex(parameter_block, r"\[bool\]\$LaunchGui\s*=\s*\$false")
        self.assertRegex(parameter_block, r"\$ModelSource\s*=\s*'Hub'")
        self.assertIn("LocalModelRoot", parameter_block)
        self.assertIn("if ($LaunchGui)", deploy)
        self.assertIn("$ExpectedGpuMemoryMiB -ne 80000", deploy)
        state_binding = deploy.index("Provisioning state does not bind")
        first_ssh = deploy.index("Checking full SSH access")
        self.assertLess(state_binding, first_ssh)
        self.assertIn("outcome -ne 'bootstrapping'", deploy)
        self.assertIn("ssh_host -ne $SshHost", deploy)
        self.assertIn("Assert-QwenModelBackup", deploy)
        self.assertIn("--model-source '$effectiveModelSource'", deploy)

    def test_hardware_gate_precedes_bootstrap_and_ready_state(self) -> None:
        deploy = source("scripts/runpod-deploy.ps1")
        hardware = deploy.index("hardware-gate.sh")
        bootstrap = deploy.index("$bootstrapCommand")
        runtime = deploy.index("runtime-gate.sh")
        endpoint = deploy.index("Start-RunPodTunnel")
        ready = deploy.index("$session.LifecycleStatus = 'ready'")
        save = deploy.index("Save-RunPodSession -Session $session")
        self.assertLess(hardware, bootstrap)
        self.assertLess(bootstrap, runtime)
        self.assertLess(runtime, endpoint)
        self.assertLess(endpoint, ready)
        self.assertLess(ready, save)
        self.assertIn(
            "$session.LlamaBuildInfo = [string]$manifest.llama_cpp.expected_build_info",
            deploy,
        )

    def test_deploy_accepts_the_versioned_plan_contract(self) -> None:
        deploy = source("scripts/runpod-deploy.ps1")
        deployment = load_json(DEPLOYMENT_MANIFEST_PATH)
        hardware = deployment["hardware"]

        profile_match = re.search(
            r"\$DeploymentProfileId\s+-ne\s+'([^']+)'", deploy
        )
        self.assertIsNotNone(profile_match)
        self.assertEqual(profile_match.group(1), deployment["deployment_profile_id"])

        gpu_match = re.search(r"\$ExpectedGpuName\s+-ne\s+'([^']+)'", deploy)
        self.assertIsNotNone(gpu_match)
        self.assertEqual(gpu_match.group(1), hardware["expected_gpu_name"])

        id_match = re.search(r"\$DeploymentId\s+-notmatch\s+'([^']+)'", deploy)
        self.assertIsNotNone(id_match)
        self.assertRegex(deployment["deployment_id"], id_match.group(1))

    def test_pretty_bootstrap_json_becomes_one_native_output_line(self) -> None:
        """Reproduce the native line split that made `cat` parse only `}`."""

        powershell = (
            shutil.which("pwsh")
            or shutil.which("powershell.exe")
            or shutil.which("powershell")
        )
        if powershell is None or shutil.which("wsl.exe") is None:
            self.skipTest("PowerShell and WSL are required for native output semantics")

        deploy = source("scripts/runpod-deploy.ps1")
        parsing = deploy[
            deploy.index("$bootstrapOutput = @(") : deploy.index(
                "if (\n    [string]$bootstrap.build_profile"
            )
        ]
        self.assertIn("jq -ce 'objects'", parsing)
        self.assertIn("$bootstrapOutput.Count -ne 1", parsing)
        self.assertIn("[string]::IsNullOrWhiteSpace", parsing)
        self.assertIn("$bootstrapOutput[0]", parsing)
        self.assertNotIn("$bootstrapOutput[-1]", parsing)

        record = {
            "completed_at": "2026-08-25T18:00:00Z",
            "build_profile": "api_only_v1",
            "selected_model": "uncensored-q6",
            "llama_cpp_revision": "bb4caa7540000000000000000000000000000000",
            "cuda_architectures": "80",
            "log_file": "/workspace/qwen-eval/logs/bootstrap.log",
        }
        with tempfile.TemporaryDirectory(dir=PROJECT_ROOT) as temporary:
            root = Path(temporary)
            bootstrap_path = root / "bootstrap.json"
            bootstrap_path.write_text(
                json.dumps(record, indent=2) + "\n", encoding="utf-8"
            )
            harness = root / "bootstrap-native-lines.ps1"
            harness.write_text(
                textwrap.dedent(
                    f"""
                    Set-StrictMode -Version Latest
                    $ErrorActionPreference = 'Stop'
                    Import-Module '{powershell_path(PROJECT_ROOT / 'scripts' / 'RunPod.Common.psm1')}' -Force
                    $module = Get-Module RunPod.Common
                    $jsonPath = '{wsl_path(bootstrap_path)}'
                    $catLines = @(& $module {{
                        param([string]$Path)
                        Invoke-BoundedNativeProcess `
                            -FilePath (Get-Command wsl.exe -ErrorAction Stop).Source `
                            -Arguments @('-d', 'Ubuntu-24.04', '--', 'cat', $Path) `
                            -TimeoutSeconds 15
                    }} $jsonPath)
                    if ($catLines.Count -le 1) {{
                        throw 'Pretty JSON did not reproduce multiple native output lines.'
                    }}
                    $compactLines = @(& $module {{
                        param([string]$Path)
                        Invoke-BoundedNativeProcess `
                            -FilePath (Get-Command wsl.exe -ErrorAction Stop).Source `
                            -Arguments @('-d', 'Ubuntu-24.04', '--', 'jq', '-ce', 'objects', $Path) `
                            -TimeoutSeconds 15
                    }} $jsonPath)
                    if (
                        $compactLines.Count -ne 1 -or
                        [string]::IsNullOrWhiteSpace([string]$compactLines[0])
                    ) {{
                        throw 'Compacted JSON was not exactly one native output line.'
                    }}
                    $bootstrap = [string]$compactLines[0] | ConvertFrom-Json -ErrorAction Stop
                    if (
                        [string]$bootstrap.build_profile -ne 'api_only_v1' -or
                        [string]$bootstrap.selected_model -ne 'uncensored-q6' -or
                        [string]$bootstrap.cuda_architectures -ne '80' -or
                        [string]$bootstrap.llama_cpp_revision -notlike 'bb4caa754*'
                    ) {{
                        throw 'Compacted bootstrap state lost its qualification fields.'
                    }}
                    Write-Output 'BOOTSTRAP_NATIVE_LINES_OK'
                    """
                ).lstrip(),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    powershell,
                    "-NoLogo",
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    powershell_path(harness),
                ],
                capture_output=True,
                text=True,
                timeout=45,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("BOOTSTRAP_NATIVE_LINES_OK", result.stdout)


if __name__ == "__main__":
    unittest.main()

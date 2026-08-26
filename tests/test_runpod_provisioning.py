from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = PROJECT_ROOT / "config" / "runpod-a100-pcie-deployment.json"
MODEL_MANIFEST = PROJECT_ROOT / "config" / "models.json"
VALIDATOR = PROJECT_ROOT / "scripts" / "validate_runpod_deployment_manifest.py"
PROVISIONER = PROJECT_ROOT / "scripts" / "runpod-provision.ps1"
PROVIDER = PROJECT_ROOT / "scripts" / "RunPod.Provider.psm1"


def powershell() -> str | None:
    return (
        shutil.which("powershell.exe")
        or shutil.which("pwsh")
        or shutil.which("powershell")
    )


def powershell_path(value: str | Path) -> str:
    text = str(value)
    executable = powershell()
    if executable and executable.lower().endswith("powershell.exe") and text.startswith("/mnt/"):
        drive = text[5].upper()
        tail = text[6:].replace("/", "\\")
        return f"{drive}:\\{tail}"
    return text


def local_path(value: str) -> Path:
    if os.name != "nt" and len(value) >= 3 and value[1:3] == ":\\":
        drive = value[0].lower()
        tail = value[3:].replace("\\", "/")
        return Path(f"/mnt/{drive}/{tail}")
    return Path(value)


def run_validator(manifest: Path, plan_output: Path | None = None) -> subprocess.CompletedProcess[str]:
    command = [sys.executable, str(VALIDATOR), "--manifest", str(manifest)]
    if plan_output is not None:
        command.extend(["--plan-output", str(plan_output)])
    return subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)


def run_powershell(arguments: list[str], *, environment: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    executable = powershell()
    if executable is None:
        raise unittest.SkipTest("PowerShell is required for RunPod provisioning tests")
    converted_arguments = [powershell_path(argument) for argument in arguments]
    return subprocess.run(
        [executable, "-NoLogo", "-NoProfile", "-NonInteractive", *converted_arguments],
        cwd=PROJECT_ROOT,
        env=environment,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        timeout=60,
        check=False,
    )


class DeploymentManifestTests(unittest.TestCase):
    def test_approved_manifest_renders_exact_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            plan_path = Path(temporary) / "plan.json"
            result = run_validator(MANIFEST, plan_path)
            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(plan_path.read_text(encoding="utf-8"))

        self.assertEqual(plan["api_base"], "https://rest.runpod.io/v1")
        self.assertEqual(plan["graphql_api_base"], "https://api.runpod.io/graphql")
        self.assertEqual(plan["target"]["cloud_type"], "SECURE")
        self.assertEqual(plan["target"]["gpu_type_id"], "NVIDIA A100 80GB PCIe")
        self.assertEqual(plan["target"]["gpu_count"], 1)
        self.assertEqual(plan["target"]["minimum_gpu_memory_mib"], 80_000)
        self.assertEqual(plan["target"]["max_compute_usd_per_hour"], 1.5)
        self.assertEqual(
            plan["target"]["image_name"],
            "runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04"
            "@sha256:61a4aafb0094cd773f11eefa378929d5a687bd775febeb78eac62fc824141fb5",
        )
        self.assertEqual(plan["target"]["volume_gb"], 120)
        self.assertEqual(plan["target"]["volume_mount_path"], "/workspace")
        self.assertEqual(plan["target"]["ports"], ["22/tcp"])
        self.assertEqual(plan["deployment_profile_id"], "a100-pcie-80gb-q6-v1")
        self.assertEqual(plan["target"]["pod_name"], plan["deployment_id"])
        self.assertEqual(plan["workload"]["model_id"], "uncensored-q6")
        self.assertEqual(plan["workload"]["context_tokens"], 262_144)
        self.assertEqual(plan["workload"]["inspect_compaction_tokens"], 160_000)
        self.assertEqual(plan["workload"]["opencode_context_tokens"], 262_144)
        self.assertEqual(plan["workload"]["opencode_output_tokens"], 32_000)
        self.assertEqual(plan["workload"]["expected_llama_build_info"], "b1-bb4caa754")
        self.assertEqual(plan["create_request"]["allowedCudaVersions"], [
            "12.4", "12.5", "12.6", "12.7", "12.8", "12.9", "13.0"
        ])
        self.assertEqual(plan["create_request"]["computeType"], "GPU")
        self.assertFalse(plan["create_request"]["interruptible"])
        self.assertFalse(plan["create_request"]["locked"])
        self.assertEqual(plan["create_request"]["minRAMPerGPU"], 50)
        self.assertEqual(plan["create_request"]["minVCPUPerGPU"], 8)
        self.assertNotIn("minMemoryInGb", plan["create_request"])
        self.assertNotIn("minVcpuCount", plan["create_request"])
        self.assertNotIn("templateId", plan["create_request"])
        self.assertNotIn("env", plan["create_request"])

    def test_plan_rendering_is_byte_stable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            first = Path(temporary) / "first.json"
            second = Path(temporary) / "second.json"
            first_result = run_validator(MANIFEST, first)
            second_result = run_validator(MANIFEST, second)
            self.assertEqual(first_result.returncode, 0, first_result.stderr)
            self.assertEqual(second_result.returncode, 0, second_result.stderr)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(
                hashlib.sha256(first.read_bytes()).hexdigest(),
                hashlib.sha256(second.read_bytes()).hexdigest(),
            )

    def test_contract_rejects_hardware_cloud_price_and_template_drift(self) -> None:
        original = json.loads(MANIFEST.read_text(encoding="utf-8"))
        mutations = [
            ("community cloud", lambda value: value["provider"].__setitem__("cloud_type", "COMMUNITY")),
            ("A100 SXM", lambda value: value["hardware"].__setitem__("gpu_type_id", "NVIDIA A100-SXM4-80GB")),
            ("price limit", lambda value: value["provider"].__setitem__("max_compute_usd_per_hour", 1.51)),
            ("119 GB", lambda value: value["container"].__setitem__("volume_gb", 119)),
            ("wrong mount", lambda value: value["container"].__setitem__("volume_mount_path", "/data")),
            ("template id", lambda value: value["container"].__setitem__("templateId", "forbidden")),
        ]
        for label, mutate in mutations:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                config = root / "config"
                config.mkdir()
                shutil.copy2(MODEL_MANIFEST, config / "models.json")
                candidate = copy.deepcopy(original)
                mutate(candidate)
                candidate_path = config / "runpod-a100-pcie-deployment.json"
                candidate_path.write_text(json.dumps(candidate), encoding="utf-8")
                result = run_validator(candidate_path)
                self.assertNotEqual(result.returncode, 0, result.stdout)


class OfflineDryRunTests(unittest.TestCase):
    def test_default_dry_run_is_offline_and_plan_is_stable(self) -> None:
        environment = os.environ.copy()
        environment.pop("RUNPOD_API_KEY", None)
        first = run_powershell(
            ["-File", str(PROVISIONER), "-OutputFormat", "Json"],
            environment=environment,
        )
        self.assertEqual(first.returncode, 0, first.stderr)
        first_output = json.loads(first.stdout.strip())
        self.assertEqual(first_output["mode"], "dry_run")
        self.assertEqual(first_output["mutation_state"], "none")
        self.assertFalse(first_output["mutation_performed"])
        self.assertEqual(first_output["provider_preflight"], "deferred_to_execute")
        plan_path = local_path(first_output["plan_path"])
        first_bytes = plan_path.read_bytes()
        self.assertEqual(hashlib.sha256(first_bytes).hexdigest(), first_output["plan_sha256"])

        second = run_powershell(
            ["-File", str(PROVISIONER), "-OutputFormat", "Json"],
            environment=environment,
        )
        self.assertEqual(second.returncode, 0, second.stderr)
        second_output = json.loads(second.stdout.strip())
        self.assertEqual(second_output["plan_sha256"], first_output["plan_sha256"])
        self.assertEqual(plan_path.read_bytes(), first_bytes)

    def test_execute_without_hash_fails_before_provider_access(self) -> None:
        environment = os.environ.copy()
        environment["RUNPOD_API_KEY"] = "offline-sentinel-must-not-be-used"
        result = run_powershell(
            ["-File", str(PROVISIONER), "-Execute", "-OutputFormat", "Json"],
            environment=environment,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ExpectedPlanSha256", result.stderr)
        self.assertNotIn("RunPod API request failed", result.stderr)

    def test_execute_with_wrong_hash_fails_before_provider_access(self) -> None:
        environment = os.environ.copy()
        environment["RUNPOD_API_KEY"] = "offline-sentinel-must-not-be-used"
        result = run_powershell(
            [
                "-File",
                str(PROVISIONER),
                "-Execute",
                "-ExpectedPlanSha256",
                "0" * 64,
                "-OutputFormat",
                "Json",
            ],
            environment=environment,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No provider request was sent", result.stderr)
        self.assertNotIn("RunPod API request failed", result.stderr)


class ProviderBoundaryTests(unittest.TestCase):
    def test_provider_module_has_fixed_api_and_single_non_retrying_create_post(self) -> None:
        provider = PROVIDER.read_text(encoding="utf-8")
        self.assertIn("$script:RunPodApiBase = 'https://rest.runpod.io/v1'", provider)
        self.assertIn("$script:RunPodGraphQLApiBase = 'https://api.runpod.io/graphql'", provider)
        self.assertNotIn("-Path '/gpuTypes'", provider)
        self.assertIn("lowestPrice(input: { gpuCount: 1, secureCloud: true })", provider)
        create = provider.split("function New-RunPodPod", 1)[1].split("function Get-RunPodPod", 1)[0]
        self.assertEqual(create.count("Invoke-RunPodRestRequest -Method POST"), 1)
        self.assertNotIn("Start-Sleep", create)
        self.assertNotIn("templateId =", create)
        self.assertNotIn("RUNPOD_API_KEY", provider)
        get_pod = provider.split("function Get-RunPodPod", 1)[1].split("function Get-RunPodPods", 1)[0]
        self.assertIn("includeMachine = 'true'", get_pod)
        self.assertIn("RunPod GET response id mismatch", get_pod)
        stop = provider.split("function Stop-RunPodPod", 1)[1].split("function Get-RunPodPodId", 1)[0]
        self.assertEqual(stop.count('Invoke-RunPodRestRequest -Method POST'), 1)
        self.assertIn("Get-RunPodPod -ApiKey", stop)
        self.assertIn("'EXITED'", stop)
        self.assertIn("did not reach EXITED", stop)

    def test_offer_guard_accepts_only_secure_a100_within_price_limit(self) -> None:
        module_path = powershell_path(PROVIDER).replace("'", "''")
        harness = f"""
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module '{module_path}' -Force
$valid = [pscustomobject]@{{
    id = 'NVIDIA A100 80GB PCIe'
    memory_in_gb = [decimal]80
    secure_cloud = $true
    secure_price = [decimal]1.39
    stock_status = 'Medium'
    available_gpu_counts = @(1)
}}
Assert-RunPodGpuOffer -Offer $valid -ExpectedGpuTypeId 'NVIDIA A100 80GB PCIe' -MinimumMemoryGb 80 -MaximumSecurePrice ([decimal]1.50)
$validNullCounts = [pscustomobject]@{{
    id = 'NVIDIA A100 80GB PCIe'
    memory_in_gb = [decimal]80
    secure_cloud = $true
    secure_price = [decimal]1.39
    stock_status = 'Low'
    available_gpu_counts = @($null)
}}
Assert-RunPodGpuOffer -Offer $validNullCounts -ExpectedGpuTypeId 'NVIDIA A100 80GB PCIe' -MinimumMemoryGb 80 -MaximumSecurePrice ([decimal]1.50)
$invalid = [pscustomobject]@{{
    id = 'NVIDIA A100 80GB PCIe'
    memory_in_gb = [decimal]80
    secure_cloud = $true
    secure_price = [decimal]1.51
    stock_status = 'High'
    available_gpu_counts = @(1)
}}
try {{
    Assert-RunPodGpuOffer -Offer $invalid -ExpectedGpuTypeId 'NVIDIA A100 80GB PCIe' -MinimumMemoryGb 80 -MaximumSecurePrice ([decimal]1.50)
    throw 'price guard unexpectedly accepted 1.51'
}}
catch {{
    if ($_.Exception.Message -eq 'price guard unexpectedly accepted 1.51') {{ throw }}
}}
$invalidCounts = [pscustomobject]@{{
    id = 'NVIDIA A100 80GB PCIe'
    memory_in_gb = [decimal]80
    secure_cloud = $true
    secure_price = [decimal]1.39
    stock_status = 'Low'
    available_gpu_counts = @(2)
}}
try {{
    Assert-RunPodGpuOffer -Offer $invalidCounts -ExpectedGpuTypeId 'NVIDIA A100 80GB PCIe' -MinimumMemoryGb 80 -MaximumSecurePrice ([decimal]1.50)
    throw 'count guard unexpectedly accepted an explicit non-single-GPU offer'
}}
catch {{
    if ($_.Exception.Message -eq 'count guard unexpectedly accepted an explicit non-single-GPU offer') {{ throw }}
}}
'ok'
"""
        with tempfile.TemporaryDirectory(dir=PROJECT_ROOT) as temporary:
            path = Path(temporary) / "provider-offer-contract.ps1"
            path.write_text(harness, encoding="utf-8")
            result = run_powershell(["-File", str(path)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ok")

    def test_rest_v1_pod_response_shape_is_bound_fail_closed(self) -> None:
        module_path = powershell_path(PROVIDER).replace("'", "''")
        harness = f"""
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module '{module_path}' -Force
$target = [pscustomobject]@{{
    pod_name = 'a100-pcie-contract-witness'
    cloud_type = 'SECURE'
    gpu_type_id = 'NVIDIA A100 80GB PCIe'
    gpu_count = 1
    image_name = 'runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04@sha256:61a4aafb0094cd773f11eefa378929d5a687bd775febeb78eac62fc824141fb5'
    volume_gb = 120
    volume_mount_path = '/workspace'
    container_disk_gb = 30
    max_compute_usd_per_hour = [decimal]1.50
}}
$pod = @'
{{
  "id":"podcontract1",
  "name":"a100-pcie-contract-witness",
  "desiredStatus":"RUNNING",
  "image":"runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04@sha256:61a4aafb0094cd773f11eefa378929d5a687bd775febeb78eac62fc824141fb5",
  "interruptible":false,
  "locked":false,
  "gpu":{{"id":"NVIDIA A100 80GB PCIe","count":1}},
  "machine":{{"gpuTypeId":"NVIDIA A100 80GB PCIe","secureCloud":true,"supportPublicIp":true}},
  "containerDiskInGb":30,
  "volumeInGb":120,
  "volumeMountPath":"/workspace",
  "ports":["22/tcp"],
  "costPerHr":"1.39"
}}
'@ | ConvertFrom-Json
$ownedId = Assert-RunPodPodOwnership -Pod $pod -ExpectedPodId 'podcontract1' -ExpectedName 'a100-pcie-contract-witness'
if ($ownedId -ne 'podcontract1') {{ throw 'official REST ownership fixture was not accepted' }}
$id = Assert-RunPodPodContract -Pod $pod -Target $target
if ($id -ne 'podcontract1') {{ throw 'official REST fixture was not accepted' }}
$livePod = @'
{{
  "id":"podcontract2",
  "name":"a100-pcie-contract-witness",
  "desiredStatus":"RUNNING",
  "gpuCount":1,
  "imageName":"runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04@sha256:61a4aafb0094cd773f11eefa378929d5a687bd775febeb78eac62fc824141fb5",
  "machine":{{"gpuTypeId":"NVIDIA A100 80GB PCIe","secureCloud":true,"supportPublicIp":true}},
  "containerDiskInGb":30,
  "volumeInGb":120,
  "volumeMountPath":"/workspace",
  "ports":["22/tcp"],
  "costPerHr":"1.39"
}}
'@ | ConvertFrom-Json
$liveId = Assert-RunPodPodContract -Pod $livePod -Target $target
if ($liveId -ne 'podcontract2') {{ throw 'current REST fixture was not accepted' }}
$livePod | Add-Member -NotePropertyName interruptible -NotePropertyValue $true
try {{
    [void](Assert-RunPodPodContract -Pod $livePod -Target $target)
    throw 'interruptible pod was accepted'
}}
catch {{
    if ($_.Exception.Message -eq 'interruptible pod was accepted') {{ throw }}
}}
$pod.PSObject.Properties.Remove('costPerHr')
try {{
    [void](Assert-RunPodPodContract -Pod $pod -Target $target)
    throw 'missing price was accepted'
}}
catch {{
    if ($_.Exception.Message -eq 'missing price was accepted') {{ throw }}
}}
'ok'
"""
        with tempfile.TemporaryDirectory(dir=PROJECT_ROOT) as temporary:
            path = Path(temporary) / "provider-rest-contract.ps1"
            path.write_text(harness, encoding="utf-8")
            result = run_powershell(["-File", str(path)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ok")

    def test_graphql_gpu_preflight_uses_official_lowest_price_shape(self) -> None:
        module_path = powershell_path(PROVIDER).replace("'", "''")
        harness = rf"""
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function global:Invoke-RestMethod {{
    param($Uri, $Method, $ContentType, $Body, $TimeoutSec, $ErrorAction)
    if ([string]$Uri -notlike 'https://api.runpod.io/graphql?api_key=*') {{
        throw 'unexpected GraphQL URI'
    }}
    $request = $Body | ConvertFrom-Json
    if (
        [string]$request.query -notmatch 'gpuTypes\(input:' -or
        [string]$request.query -notmatch 'secureCloud:\s*true' -or
        [string]$request.query -notmatch 'uninterruptablePrice' -or
        [string]$request.query -notmatch 'availableGpuCounts'
    ) {{
        throw 'GraphQL query does not use the published GPU preflight shape'
    }}
    return @'
{{
  "data":{{
    "gpuTypes":[{{
      "id":"NVIDIA A100 80GB PCIe",
      "displayName":"A100 PCIe 80 GB",
      "memoryInGb":80,
      "secureCloud":true,
      "lowestPrice":{{
        "stockStatus":"Medium",
        "uninterruptablePrice":1.39,
        "availableGpuCounts":[1]
      }}
    }}]
  }}
}}
'@ | ConvertFrom-Json
}}
try {{
    Import-Module '{module_path}' -Force
    $offer = Get-RunPodGpuOffer -ApiKey 'offline-fixture-key' -GpuTypeId 'NVIDIA A100 80GB PCIe'
    Assert-RunPodGpuOffer -Offer $offer -ExpectedGpuTypeId 'NVIDIA A100 80GB PCIe' -MinimumMemoryGb 80 -MaximumSecurePrice ([decimal]1.50)
    if ([decimal]$offer.secure_price -ne [decimal]1.39) {{ throw 'wrong parsed price' }}
    'ok'
}}
finally {{
    Remove-Item Function:\Invoke-RestMethod -Force -ErrorAction SilentlyContinue
}}
"""
        with tempfile.TemporaryDirectory(dir=PROJECT_ROOT) as temporary:
            path = Path(temporary) / "provider-graphql-contract.ps1"
            path.write_text(harness, encoding="utf-8")
            result = run_powershell(["-File", str(path)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ok")

    def test_provisioner_passes_bound_deployment_metadata_and_hides_provider_key(self) -> None:
        source = PROVISIONER.read_text(encoding="utf-8")
        self.assertEqual(source.count("$pod = New-RunPodPod"), 1)
        self.assertIn("Get-RunPodPodsByName", source)
        self.assertIn("Stop-RunPodPod", source)
        self.assertIn("stopped_after_failure", source)
        self.assertIn("$ownershipBound", source)
        self.assertIn("Assert-RunPodPodOwnership", source)
        self.assertIn("create_submitted_but_exact_name_and_contract_ownership_not_bound_no_stop_attempted", source)
        self.assertNotIn("($rollbackEligible -or $createSubmitted)", source)
        qualification = source.index("[void](Assert-RunPodPodContract -Pod $pod -Target $plan.target)", source.index("if ($createSubmitted -and -not $ownershipBound)"))
        ownership = source.index("[void](Assert-RunPodPodOwnership", source.index("if ($createSubmitted -and -not $ownershipBound)"))
        self.assertLess(ownership, qualification)
        disable = source.split("function Disable-BoundRunPodSession", 1)[1].split("function Get-OwnedRunPodCandidate", 1)[0]
        self.assertLess(disable.index("LifecycleStatus"), disable.index("Stop-RunPodTunnel"))
        self.assertIn("$session.PSObject.Properties['PodId']", disable)
        self.assertIn("$session.PSObject.Properties['DeploymentPlanSha256']", disable)
        self.assertNotIn("$session.PodId", disable)
        for parameter in (
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
            self.assertIn(f"{parameter} =", source)
        self.assertIn("LaunchGui = $false", source)
        self.assertIn("ModelSource = if ($effectiveModelSource", source)
        self.assertIn("LocalModelRoot = $resolvedLocalModelRoot", source)
        self.assertIn("Remove-Item Env:RUNPOD_API_KEY", source)
        self.assertNotIn("providerApiKey =", source.split("$readyState =", 1)[1])

    def test_local_backup_preflight_precedes_provider_access(self) -> None:
        source = PROVISIONER.read_text(encoding="utf-8")
        preflight = source.index("Preflighting the complete external model backup")
        provider = source.index("Import-Module $providerModulePath")
        self.assertLess(preflight, provider)
        self.assertIn("Assert-QwenModelBackup", source[:provider])

    def test_ready_adoption_uses_exact_model_source_binding_gate(self) -> None:
        source = PROVISIONER.read_text(encoding="utf-8")
        binding = source.index("Test-QwenReadyModelSourceBinding")
        ready_decision = source.index("if ($localSessionReady)", binding)
        self.assertLess(binding, ready_decision)
        self.assertIn("$modelSourceBindingReady", source[binding:ready_decision])
        self.assertIn("-ExpectedBackupManifestSha256 $effectiveBackupManifestSha256", source)
        self.assertIn("-RequiredModel ([string]$plan.workload.model_id)", source)

    def test_adoption_skips_global_offer_but_create_requires_it(self) -> None:
        def prepare_fixture(root: Path, *, existing_state: bool) -> tuple[Path, dict[str, str], Path, Path, Path]:
            scripts = root / "scripts"
            config = root / "config"
            evals = root / "evals"
            profile = root / ".runpod" / "deployments" / "a100-pcie-80gb-q6-v1"
            scripts.mkdir(parents=True)
            config.mkdir(parents=True)
            evals.mkdir(parents=True)
            profile.mkdir(parents=True)
            for name in (
                "runpod-provision.ps1",
                "validate_runpod_deployment_manifest.py",
                "RunPod.Provider.psm1",
                "RunPod.Common.psm1",
                "ModelBackup.Common.psm1",
            ):
                shutil.copy2(PROJECT_ROOT / "scripts" / name, scripts / name)
            shutil.copy2(MANIFEST, config / MANIFEST.name)
            shutil.copy2(MODEL_MANIFEST, config / MODEL_MANIFEST.name)
            shutil.copy2(PROJECT_ROOT / "evals" / "cybench.py", evals / "cybench.py")
            shutil.copy2(PROJECT_ROOT / "opencode.jsonc", root / "opencode.jsonc")

            plan_path = profile / "plan.json"
            rendered = run_validator(config / MANIFEST.name, plan_path)
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            plan_bytes = plan_path.read_bytes()
            plan_hash = hashlib.sha256(plan_bytes).hexdigest()
            plan = json.loads(plan_bytes)
            pod_id = "podadopt01"
            if existing_state:
                (profile / "state.json").write_text(
                    json.dumps(
                        {
                            "schema_version": 1,
                            "deployment_id": plan["deployment_id"],
                            "deployment_profile_id": plan["deployment_profile_id"],
                            "plan_sha256": plan_hash,
                            "mutation_state": "created",
                            "outcome": "stopped_after_failure",
                            "pod_id": pod_id,
                        }
                    ),
                    encoding="utf-8",
                )

            identity = root / "identity"
            identity.write_text("offline-test-key", encoding="ascii")
            offer_marker = root / "offer-called"
            create_marker = root / "create-called"
            deploy_marker = root / "deploy-called"

            def ps_literal(value: str | Path) -> str:
                return powershell_path(value).replace("'", "''")

            (scripts / "runpod-deploy.ps1").write_text(
                r"""
param(
    [string]$SshHost, [int]$SshPort, [string]$SshUser,
    [string]$IdentityFile, [string]$PodId, [string]$DeploymentId,
    [string]$DeploymentProfileId, [string]$DeploymentPlanSha256,
    [string]$ProvisioningStatePath, [string]$ExpectedGpuName,
    [int]$ExpectedGpuMemoryMiB, [string]$ExpectedComputeCapability,
    [string]$ExpectedCudaRelease, [string]$Model, [bool]$DownloadAll,
    [string]$ModelSource, [string]$LocalModelRoot,
    [bool]$LaunchGui, [int]$LocalPort, [string]$RemoteDir
)
$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrWhiteSpace([string]$env:RUNPOD_API_KEY)) {
    throw 'provider key leaked into deploy child'
}
$state = Get-Content -LiteralPath $ProvisioningStatePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$state.outcome -ne 'bootstrapping' -or [string]$state.pod_id -ne $PodId) {
    throw 'deploy did not receive bound bootstrapping state'
}
[IO.File]::WriteAllText($env:TEST_DEPLOY_MARKER, 'called')
""".strip()
                + "\n",
                encoding="utf-8",
            )

            launcher = root / "invoke-provisioner.ps1"
            launcher.write_text(
                f"""
param([int]$TestSshPort)
$env:RUNPOD_API_KEY = 'offline-fixture-provider-key'
$env:TEST_PROVISIONER = '{ps_literal(scripts / "runpod-provision.ps1")}'
$env:TEST_PLAN_SHA256 = '{plan_hash}'
$env:TEST_IDENTITY = '{ps_literal(identity)}'
$env:TEST_POD_ID = '{pod_id}'
$env:TEST_POD_NAME = '{plan["target"]["pod_name"]}'
$env:TEST_OFFER_MARKER = '{ps_literal(offer_marker)}'
$env:TEST_CREATE_MARKER = '{ps_literal(create_marker)}'
$env:TEST_DEPLOY_MARKER = '{ps_literal(deploy_marker)}'
$env:TEST_SSH_PORT = [string]$TestSshPort
""".lstrip()
                + r"""
$ErrorActionPreference = 'Stop'
function global:Invoke-RestMethod {
    param($Uri, $Method, $Headers, $TimeoutSec, $ErrorAction, $ContentType, $Body)
    $requestUri = [string]$Uri
    if ($requestUri -like 'https://api.runpod.io/graphql?api_key=*') {
        [IO.File]::WriteAllText($env:TEST_OFFER_MARKER, 'called')
        return [pscustomobject]@{
            data = [pscustomobject]@{
                gpuTypes = @([pscustomobject]@{
                    id = 'NVIDIA A100 80GB PCIe'
                    displayName = 'A100 PCIe 80 GB'
                    memoryInGb = 80
                    secureCloud = $true
                    lowestPrice = [pscustomobject]@{
                        stockStatus = 'None'
                        uninterruptablePrice = [decimal]1.39
                        availableGpuCounts = @(1)
                    }
                })
            }
        }
    }
    if ($requestUri.StartsWith('https://rest.runpod.io/v1/pods?')) {
        return [pscustomobject]@{ data = @() }
    }
    if ($requestUri -like 'https://rest.runpod.io/v1/pods/*') {
        if ([string]$Method -eq 'POST') {
            [IO.File]::WriteAllText($env:TEST_CREATE_MARKER, 'called')
            throw 'create must not be reached after unavailable stock'
        }
        return [pscustomobject]@{
            id = $env:TEST_POD_ID
            name = $env:TEST_POD_NAME
            desiredStatus = 'RUNNING'
            gpuCount = 1
            imageName = 'runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04@sha256:61a4aafb0094cd773f11eefa378929d5a687bd775febeb78eac62fc824141fb5'
            machine = [pscustomobject]@{
                gpuTypeId = 'NVIDIA A100 80GB PCIe'
                secureCloud = $true
                supportPublicIp = $true
            }
            containerDiskInGb = 30
            volumeInGb = 120
            volumeMountPath = '/workspace'
            ports = @('22/tcp')
            costPerHr = [decimal]1.39
            publicIp = '127.0.0.1'
            portMappings = [pscustomobject]@{ '22' = [int]$env:TEST_SSH_PORT }
        }
    }
    throw "unexpected offline request: $requestUri"
}
try {
    & $env:TEST_PROVISIONER `
        -Execute `
        -ExpectedPlanSha256 $env:TEST_PLAN_SHA256 `
        -IdentityFile $env:TEST_IDENTITY `
        -OutputFormat Json
}
finally {
    Remove-Item Function:\Invoke-RestMethod -Force -ErrorAction SilentlyContinue
}
""".strip()
                + "\n",
                encoding="utf-8",
            )
            environment = os.environ.copy()
            return launcher, environment, offer_marker, create_marker, deploy_marker

        with tempfile.TemporaryDirectory(dir=PROJECT_ROOT) as temporary:
            root = Path(temporary)
            launcher, environment, offer_marker, create_marker, deploy_marker = prepare_fixture(
                root, existing_state=True
            )
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
                listener.bind(("127.0.0.1", 0))
                listener.listen(1)
                adopted = run_powershell(
                    ["-File", str(launcher), "-TestSshPort", str(listener.getsockname()[1])],
                    environment=environment,
                )
            self.assertEqual(adopted.returncode, 0, adopted.stderr)
            result = json.loads(adopted.stdout.strip())
            self.assertEqual(result["mutation_state"], "adopted")
            self.assertFalse(result["mutation_performed"])
            self.assertEqual(result["outcome"], "ready")
            self.assertEqual(result["effective_spec"]["compute_usd_per_hour"], 1.39)
            self.assertFalse(offer_marker.exists(), "adoption consulted global stock")
            self.assertFalse(create_marker.exists(), "adoption submitted a create POST")
            self.assertTrue(deploy_marker.exists(), "adoption did not reach deploy")

        with tempfile.TemporaryDirectory(dir=PROJECT_ROOT) as temporary:
            root = Path(temporary)
            launcher, environment, offer_marker, create_marker, deploy_marker = prepare_fixture(
                root, existing_state=False
            )
            create_attempt = run_powershell(
                ["-File", str(launcher), "-TestSshPort", "1"],
                environment=environment,
            )
            self.assertNotEqual(create_attempt.returncode, 0)
            self.assertIn("no reported stock", create_attempt.stderr)
            self.assertTrue(offer_marker.exists(), "create path skipped the required offer gate")
            self.assertFalse(create_marker.exists(), "create POST ran after the offer gate failed")
            self.assertFalse(deploy_marker.exists(), "failed create preflight reached deploy")

    def test_new_powershell_files_parse_in_windows_powershell(self) -> None:
        executable = powershell()
        if executable is None:
            self.skipTest("PowerShell is required for parser checks")
        for path in (PROVIDER, PROVISIONER):
            escaped = powershell_path(path).replace("'", "''")
            command = (
                "$errors=$null; "
                f"[void][Management.Automation.Language.Parser]::ParseFile('{escaped}',[ref]$null,[ref]$errors); "
                "if($errors.Count -gt 0){$errors | ForEach-Object {Write-Error $_}; exit 1}"
            )
            result = run_powershell(["-Command", command])
            self.assertEqual(result.returncode, 0, f"{path}: {result.stderr}")


if __name__ == "__main__":
    unittest.main()

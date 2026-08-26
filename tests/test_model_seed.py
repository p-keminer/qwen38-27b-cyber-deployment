import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]


class ModelSeedContractTests(unittest.TestCase):
    def test_recovery_command_restores_previous_generation_after_interruption(self):
        powershell = (
            shutil.which("powershell.exe")
            or shutil.which("pwsh")
            or shutil.which("powershell")
        )
        if powershell is None:
            self.skipTest("PowerShell is required")
        if os.name == "nt":
            if shutil.which("wsl.exe") is None:
                self.skipTest("WSL bash is required")
            bash_prefix = [
                "wsl.exe", "-d", "Ubuntu-24.04", "-u", "root", "--", "bash", "-c"
            ]
            module_path = str(ROOT / "scripts" / "RemoteModelActivation.Common.psm1")
        else:
            if shutil.which("bash") is None:
                self.skipTest("bash is required")
            if not os.access("/workspace", os.W_OK):
                self.skipTest("writable /workspace is required for the recovery fixture")
            bash_prefix = ["bash", "-c"]
            module_path = str(ROOT / "scripts" / "RemoteModelActivation.Common.psm1")
            if Path(powershell).name.lower() == "powershell.exe":
                module_path = subprocess.run(
                    ["wslpath", "-w", module_path],
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=10,
                ).stdout.strip()

        remote_dir = f"/workspace/qwen-activation-test-{uuid.uuid4().hex}"
        model_sha = hashlib.sha256(b"good").hexdigest()
        projector_sha = hashlib.sha256(b"vision").hexdigest()
        owner = "a" * 32
        module_literal = module_path.replace("'", "''")
        ps_command = f"""
Import-Module '{module_literal}' -Force
$artifacts = @(
  [pscustomobject]@{{Filename='model.gguf';Size=4;Sha256='{model_sha}'}},
  [pscustomobject]@{{Filename='projector.gguf';Size=6;Sha256='{projector_sha}'}}
)
Get-QwenRemoteModelRecoveryCommand -RemoteDir '{remote_dir}' -Model whitehat-q4 -Artifacts $artifacts -AllowStaleRecovery
"""
        generated = subprocess.run(
            [powershell, "-NoProfile", "-Command", ps_command],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(generated.returncode, 0, generated.stderr)
        recovery = generated.stdout.strip()
        transaction = f"{remote_dir}/models/.activation-whitehat-q4"
        final = f"{remote_dir}/models/whitehat-q4"

        def run_bash(script: str) -> subprocess.CompletedProcess[str]:
            encoded = base64.b64encode(script.encode("utf-8")).decode("ascii")
            launcher = f"printf '%s' '{encoded}' | base64 -d | bash"
            return subprocess.run(
                bash_prefix + [launcher], capture_output=True, text=True, timeout=30
            )

        try:
            interrupted = (
                f"set -eu; rm -rf -- '{remote_dir}'; "
                f"mkdir -p '{transaction}/previous' '{transaction}/generation-{'b' * 32}'; "
                f"printf '{owner}' >'{transaction}/owner'; "
                f"printf previous_moved >'{transaction}/phase'; "
                f"printf good >'{transaction}/previous/model.gguf'; "
                f"printf vision >'{transaction}/previous/projector.gguf'; "
                f"test -f '{transaction}/previous/model.gguf'; test ! -e '{final}'; "
                f"printf partial >'{transaction}/generation-{'b' * 32}/model.gguf'; {recovery}; "
                f"test \"$(cat '{final}/model.gguf')\" = good; "
                f"test \"$(cat '{final}/projector.gguf')\" = vision; "
                f"test ! -e '{transaction}'"
            )
            first = run_bash(interrupted)
            self.assertEqual(first.returncode, 0, first.stderr)

            invalid_active = (
                f"set -eu; mkdir -p '{transaction}/previous'; "
                f"printf '{owner}' >'{transaction}/owner'; "
                f"printf activated >'{transaction}/phase'; "
                f"printf good >'{transaction}/previous/model.gguf'; "
                f"printf vision >'{transaction}/previous/projector.gguf'; "
                f"printf evil >'{final}/model.gguf'; "
                f"printf vision >'{final}/projector.gguf'; {recovery}; "
                f"test \"$(cat '{final}/model.gguf')\" = good; "
                f"test ! -e '{transaction}'"
            )
            second = run_bash(invalid_active)
            self.assertEqual(second.returncode, 0, second.stderr)
        finally:
            run_bash(f"rm -rf -- '{remote_dir}'")

    def test_recovery_fails_closed_for_unsafe_paths_move_failure_and_foreign_owner(self):
        powershell = (
            shutil.which("powershell.exe")
            or shutil.which("pwsh")
            or shutil.which("powershell")
        )
        if powershell is None:
            self.skipTest("PowerShell is required")
        if os.name == "nt":
            if shutil.which("wsl.exe") is None:
                self.skipTest("WSL bash is required")
            bash_prefix = [
                "wsl.exe", "-d", "Ubuntu-24.04", "-u", "root", "--", "bash", "-c"
            ]
            module_path = str(ROOT / "scripts" / "RemoteModelActivation.Common.psm1")
        else:
            if shutil.which("bash") is None or not os.access("/workspace", os.W_OK):
                self.skipTest("writable /workspace and bash are required")
            bash_prefix = ["bash", "-c"]
            module_path = str(ROOT / "scripts" / "RemoteModelActivation.Common.psm1")

        remote_dir = f"/workspace/qwen-activation-negative-{uuid.uuid4().hex}"
        module_literal = module_path.replace("'", "''")
        model_sha = hashlib.sha256(b"good").hexdigest()
        projector_sha = hashlib.sha256(b"vision").hexdigest()
        contender = "c" * 32
        command = f"""
Import-Module '{module_literal}' -Force
$artifacts = @(
  [pscustomobject]@{{Filename='model.gguf';Size=4;Sha256='{model_sha}'}},
  [pscustomobject]@{{Filename='projector.gguf';Size=6;Sha256='{projector_sha}'}}
)
[pscustomobject]@{{
  Stale = Get-QwenRemoteModelRecoveryCommand -RemoteDir '{remote_dir}' -Model whitehat-q4 -Artifacts $artifacts -AllowStaleRecovery
  Contender = Get-QwenRemoteModelRecoveryCommand -RemoteDir '{remote_dir}' -Model whitehat-q4 -Artifacts $artifacts -ExpectedOwnerToken '{contender}'
}} | ConvertTo-Json -Compress
"""
        generated = subprocess.run(
            [powershell, "-NoProfile", "-Command", command],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(generated.returncode, 0, generated.stderr)
        commands = json.loads(generated.stdout.strip().splitlines()[-1])
        stale64 = base64.b64encode(commands["Stale"].encode()).decode()
        contender64 = base64.b64encode(commands["Contender"].encode()).decode()
        transaction = f"{remote_dir}/models/.activation-whitehat-q4"
        final = f"{remote_dir}/models/whitehat-q4"
        owner = "a" * 32
        generation = "b" * 32
        fake_bin = f"/tmp/qwen-activation-mv-{uuid.uuid4().hex}"
        script = f"""
set -eu
root='{remote_dir}'
txn='{transaction}'
final='{final}'
fake_bin='{fake_bin}'
cleanup() {{ /bin/rm -rf -- "$root" "$fake_bin"; }}
trap cleanup EXIT
stale=$(printf '%s' '{stale64}' | base64 -d)
contender=$(printf '%s' '{contender64}' | base64 -d)

/bin/mkdir -p "$txn/previous"
printf '%s' '{owner}' >"$txn/owner"
printf '%s' previous_moved >"$txn/phase"
printf good >"$txn/previous/model.gguf"
printf vision >"$txn/previous/projector.gguf"
printf blocker >"$final"
set +e
regular_output=$(bash -c "$stale" 2>&1)
regular_status=$?
set -e
test "$regular_status" -ne 0
test -f "$final"
test -d "$txn/previous"
test "$(cat "$txn/previous/model.gguf")" = good
! printf '%s' "$regular_output" | grep -q RECOVERY_OK

/bin/rm -rf -- "$root"
/bin/mkdir -p "$txn/previous" "$fake_bin"
printf '%s' '{owner}' >"$txn/owner"
printf '%s' previous_moved >"$txn/phase"
printf good >"$txn/previous/model.gguf"
printf vision >"$txn/previous/projector.gguf"
printf '#!/bin/sh\nif test "$1" = -f; then exec /bin/mv "$@"; fi\nexit 42\n' >"$fake_bin/mv"
/bin/chmod 700 "$fake_bin/mv"
set +e
move_output=$(PATH="$fake_bin:/usr/bin:/bin" bash -c "$stale" 2>&1)
move_status=$?
set -e
test "$move_status" -ne 0
test ! -e "$final"
test -d "$txn/previous"
test "$(cat "$txn/previous/model.gguf")" = good
test "$(cat "$txn/phase")" = rollback_pending
! printf '%s' "$move_output" | grep -q RECOVERY_OK
retry_output=$(bash -c "$stale" 2>&1)
test "$retry_output" = RECOVERY_OK
test "$(cat "$final/model.gguf")" = good
test ! -e "$txn"

/bin/rm -rf -- "$root"
/bin/mkdir -p "$txn/generation-{generation}"
printf '%s' '{owner}' >"$txn/owner"
printf '%s' 'uploading:{generation}' >"$txn/phase"
set +e
foreign_output=$(bash -c "$contender" 2>&1)
foreign_status=$?
set -e
test "$foreign_status" -ne 0
test -d "$txn/generation-{generation}"
test "$(cat "$txn/owner")" = '{owner}'
printf '%s' "$foreign_output" | grep -q 'foreign or live model activation transaction refused'
! printf '%s' "$foreign_output" | grep -q RECOVERY_OK
"""
        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            script_path = Path(temporary) / "negative-recovery.sh"
            script_path.write_text(script, encoding="utf-8", newline="\n")
            if os.name == "nt":
                resolved_script = script_path.resolve()
                wsl_script = (
                    f"/mnt/{resolved_script.drive[0].lower()}"
                    + str(resolved_script)[2:].replace("\\", "/")
                )
                invocation = [
                    "wsl.exe", "-d", "Ubuntu-24.04", "-u", "root", "--",
                    "bash", wsl_script,
                ]
            else:
                invocation = ["bash", str(script_path)]
            result = subprocess.run(
                invocation,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_seed_is_qualified_content_addressed_and_local_only(self):
        source = (ROOT / "scripts" / "runpod-seed-model.ps1").read_text(
            encoding="utf-8"
        )
        activation = (ROOT / "scripts" / "RemoteModelActivation.Common.psm1").read_text(
            encoding="utf-8"
        )
        self.assertIn("Assert-RunPodQualifiedSession", source)
        self.assertIn("content-addressed-hub-or-verified-local-v1", source)
        self.assertIn("Assert-QwenModelBackup", source)
        self.assertIn("sha256sum '$remoteDir/config/models.json'", source)
        self.assertIn("Invoke-QwenRemoteModelActivation", source)
        self.assertIn("QWEN_MODEL_SOURCE=local-only", activation)
        self.assertNotIn("hf download", source + activation)

    def test_seed_uses_shared_crash_recoverable_transaction(self):
        seed = (ROOT / "scripts" / "runpod-seed-model.ps1").read_text(
            encoding="utf-8"
        )
        deploy = (ROOT / "scripts" / "runpod-deploy.ps1").read_text(encoding="utf-8")
        activation = (ROOT / "scripts" / "RemoteModelActivation.Common.psm1").read_text(
            encoding="utf-8"
        )
        self.assertIn("Invoke-QwenRemoteModelActivation", seed)
        self.assertIn("Invoke-QwenRemoteModelActivation", deploy)
        self.assertNotIn(".incoming-$Model-$uploadId", seed + deploy)
        self.assertIn(".activation-$Model", activation)
        self.assertIn("generation-$activationId", activation)
        self.assertIn("[Guid]::NewGuid().ToString('N')", activation)
        self.assertIn("previous_moved", activation)
        self.assertIn("Repair-QwenRemoteModelActivation", activation)
        self.assertIn("sha256sum -c -", activation)
        self.assertIn("test ! -L '$path'", activation)
        self.assertIn("5 GiB reserve", activation)

    def test_deployment_plan_approves_only_content_addressed_sources(self):
        manifest = (
            ROOT / "config" / "runpod-a100-pcie-deployment.json"
        ).read_text(encoding="utf-8")
        validator = (
            ROOT / "scripts" / "validate_runpod_deployment_manifest.py"
        ).read_text(encoding="utf-8")
        provision = (ROOT / "scripts" / "runpod-provision.ps1").read_text(
            encoding="utf-8"
        )
        policy = "content-addressed-hub-or-verified-local-v1"
        self.assertIn(policy, manifest)
        self.assertIn(policy, validator)
        self.assertIn(policy, provision)
        self.assertIn("model_source_policy", provision)
        self.assertIn("model_backup_manifest_sha256", provision)

    def test_switch_seeds_q4_and_never_falls_back_to_hub_in_local_mode(self):
        source = (ROOT / "scripts" / "runpod-switch.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("LocalModelRoot", source)
        self.assertIn("runpod-seed-model.ps1", source)
        self.assertIn("$localOnlySession", source)
        self.assertIn("QWEN_MODEL_SOURCE=$remoteModelSource", source)
        self.assertIn("if ($useLocalArchive) { 'local-only' }", source)
        self.assertIn("No verified external archive profile exists", source)

    def test_direct_deploy_gui_is_explicitly_offline_by_default(self):
        source = (ROOT / "scripts" / "runpod-deploy.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("[string]$GuiNetworkMode = 'Offline'", source)
        self.assertIn("-ControlledWeb:($GuiNetworkMode -eq 'ControlledWeb')", source)

    def test_seed_success_path_runs_through_fake_ssh_and_scp(self):
        powershell = (
            shutil.which("powershell.exe")
            or shutil.which("pwsh")
            or shutil.which("powershell")
        )
        if powershell is None:
            self.skipTest("PowerShell is required")

        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            fixture = Path(temporary) / "seed fixture"
            scripts = fixture / "scripts"
            project = fixture / "project"
            vault = fixture / "vault"
            model_dir = vault / "whitehat-q4"
            scripts.mkdir(parents=True)
            project.mkdir()
            model_dir.mkdir(parents=True)
            shutil.copy2(ROOT / "scripts" / "runpod-seed-model.ps1", scripts)
            shutil.copy2(
                ROOT / "scripts" / "RemoteModelActivation.Common.psm1", scripts
            )

            model_path = model_dir / "model.gguf"
            projector_path = model_dir / "projector.gguf"
            model_path.write_bytes(b"tiny model")
            projector_path.write_bytes(b"tiny projector")
            manifest_sha = hashlib.sha256(b"fixture manifest").hexdigest()
            log_path = fixture / "remote.log"

            def ps(value: Path | str) -> str:
                text = str(value)
                if os.name != "nt" and Path(powershell).name.lower() == "powershell.exe":
                    converted = subprocess.run(
                        ["wslpath", "-w", text],
                        capture_output=True,
                        text=True,
                        check=True,
                        timeout=10,
                    )
                    text = converted.stdout.strip()
                return text.replace("'", "''")

            identity = fixture / "identity"
            identity.write_text("fixture", encoding="utf-8")
            (scripts / "RunPod.Common.psm1").write_text(
                f"""
function Get-QwenProjectRoot {{ '{ps(project)}' }}
function Get-RunPodSession {{
  [pscustomobject]@{{
    SshHost='example.test'; SshPort=22; SshUser='root'; IdentityFile='{ps(identity)}';
    RemoteDir='/workspace/qwen-eval'; PodId='abcdefgh'; DeploymentId='a100-pcie-fixture1234';
    DeploymentProfileId='a100-pcie-80gb-q6-v1'; DeploymentPlanSha256=('a'*64);
    LifecycleStatus='ready'; GpuName='NVIDIA A100 80GB PCIe'; GpuCount=1;
    GpuMemoryMiB=80000; ComputeCapability='8.0'; CudaRelease='12.4';
    LlamaBuildInfo='b1-bb4caa754'; ModelSourcePolicy='content-addressed-hub-or-verified-local-v1'
  }}
}}
function Assert-RunPodQualifiedSession {{ param($Session) }}
function Invoke-RunPodSshBounded {{
  param($Session,[string]$RemoteCommand,[int]$TimeoutSeconds)
  Add-Content -LiteralPath '{ps(log_path)}' -Value "BOUNDED $RemoteCommand"
  if($RemoteCommand -like '*config/models.json*') {{ return '{manifest_sha}' }}
  if($RemoteCommand -like '*RECOVERY_OK*') {{ return 'RECOVERY_OK' }}
  if($RemoteCommand -like '*df -PB1*') {{ return '99999999999' }}
  if($RemoteCommand -like '*REMOTE_MISSING*') {{ return 'REMOTE_MISSING' }}
  if($RemoteCommand -like '*REMOTE_VERIFIED*') {{
    if($env:QWEN_FIXTURE_FAIL_FINAL -eq '1') {{ throw 'fixture final verification failure' }}
    return 'REMOTE_VERIFIED'
  }}
  if($RemoteCommand -like '*COMMIT_OK*') {{ return 'COMMIT_OK' }}
  throw 'unexpected bounded command'
}}
function Invoke-RunPodSsh {{
  param($Session,[string]$RemoteCommand)
  Add-Content -LiteralPath '{ps(log_path)}' -Value "SSH $RemoteCommand"
}}
function Copy-RunPodItem {{
  param($Session,[string]$LocalPath,[string]$RemotePath,[switch]$Recurse)
  Add-Content -LiteralPath '{ps(log_path)}' -Value "COPY $LocalPath -> $RemotePath"
}}
function Save-RunPodSession {{ param($Session) Add-Content -LiteralPath '{ps(log_path)}' -Value 'SAVE' }}
Export-ModuleMember -Function *
""".strip()
                + "\n",
                encoding="utf-8",
            )
            (scripts / "ModelBackup.Common.psm1").write_text(
                f"""
function Resolve-QwenModelBackupRoot {{ param($BackupRoot,$ProjectRoot,[switch]$Required) '{ps(vault)}' }}
function Assert-QwenModelBackup {{
  param($ProjectRoot,$BackupRoot,$Model)
  [pscustomobject]@{{
    ManifestSha256='{manifest_sha}';
    Artifacts=@(
      [pscustomobject]@{{Filename='model.gguf';Path='{ps(model_path)}';Size=10;Sha256=('1'*64)}},
      [pscustomobject]@{{Filename='projector.gguf';Path='{ps(projector_path)}';Size=14;Sha256=('2'*64)}}
    )
  }}
}}
Export-ModuleMember -Function *
""".strip()
                + "\n",
                encoding="utf-8",
            )

            script_arg = ps(scripts / "runpod-seed-model.ps1")
            result = subprocess.run(
                [
                    powershell,
                    "-NoProfile",
                    "-File",
                    script_arg,
                    "-Model",
                    "whitehat-q4",
                    "-BackupRoot",
                    ps(vault),
                ],
                cwd=ROOT,
                capture_output=True,
                timeout=30,
                check=False,
            )
            stdout = result.stdout.decode("utf-8", errors="replace")
            stderr = result.stderr.decode("utf-8", errors="replace")
            self.assertEqual(result.returncode, 0, stderr)
            json_lines = [
                line.strip()
                for line in stdout.splitlines()
                if line.strip().startswith("{") and line.strip().endswith("}")
            ]
            self.assertTrue(json_lines, repr(stdout))
            report = json.loads(json_lines[-1])
            self.assertTrue(report["remote_verified"])
            self.assertTrue(report["uploaded"])
            log = log_path.read_text(encoding="utf-8")
            self.assertIn("REMOTE_MISSING", log)
            self.assertIn("COPY", log)
            self.assertIn("sha256sum -c -", log)
            self.assertIn(".activation-whitehat-q4/generation-", log)
            self.assertIn("previous_moved", log)
            self.assertIn("RECOVERY_OK", log)
            self.assertIn("REMOTE_VERIFIED", log)
            self.assertIn("consumer_verified", log)
            self.assertIn("COMMIT_OK", log)
            self.assertIn("SAVE", log)

            logged_commands = [
                line.split(" ", 1)[1]
                for line in log.splitlines()
                if line.startswith(("SSH ", "BOUNDED "))
            ]
            for index, needle in enumerate(
                (
                    "model activation transaction creation failed",
                    "activated phase write failed",
                    "COMMIT_OK",
                )
            ):
                remote_command = next(
                    command for command in logged_commands if needle in command
                )
                command_path = fixture / f"remote-command-{index}.sh"
                command_path.write_text(remote_command, encoding="utf-8", newline="\n")
                if os.name == "nt":
                    resolved_command = command_path.resolve()
                    bash_path = (
                        f"/mnt/{resolved_command.drive[0].lower()}"
                        + str(resolved_command)[2:].replace("\\", "/")
                    )
                    parser_invocation = [
                        "wsl.exe", "-d", "Ubuntu-24.04", "-u", "root", "--",
                        "bash", "-n", bash_path,
                    ]
                else:
                    parser_invocation = ["bash", "-n", str(command_path)]
                parsed = subprocess.run(
                    parser_invocation,
                    capture_output=True,
                    text=True,
                    timeout=30,
                    check=False,
                )
                self.assertEqual(parsed.returncode, 0, parsed.stderr)

            log_path.write_text("", encoding="utf-8")
            failure_environment = os.environ.copy()
            failure_environment["QWEN_FIXTURE_FAIL_FINAL"] = "1"
            if os.name != "nt" and Path(powershell).name.lower() == "powershell.exe":
                shared = [
                    item
                    for item in failure_environment.get("WSLENV", "").split(":")
                    if item
                ]
                if "QWEN_FIXTURE_FAIL_FINAL" not in shared:
                    shared.append("QWEN_FIXTURE_FAIL_FINAL")
                failure_environment["WSLENV"] = ":".join(shared)
            failed = subprocess.run(
                [
                    powershell,
                    "-NoProfile",
                    "-File",
                    script_arg,
                    "-Model",
                    "whitehat-q4",
                    "-BackupRoot",
                    ps(vault),
                ],
                cwd=ROOT,
                capture_output=True,
                timeout=30,
                check=False,
                env=failure_environment,
            )
            failed_stderr = failed.stderr.decode("utf-8", errors="replace")
            self.assertNotEqual(failed.returncode, 0, failed_stderr)
            failure_log = log_path.read_text(encoding="utf-8")
            recovery_positions = [
                index
                for index in range(len(failure_log))
                if failure_log.startswith("BOUNDED", index)
                and "RECOVERY_OK" in failure_log[index:failure_log.find("\n", index)]
            ]
            self.assertGreaterEqual(len(recovery_positions), 2, failure_log)
            activated_position = failure_log.index("activated")
            final_verify_position = failure_log.rindex("modelctl.sh' verify")
            rollback_position = recovery_positions[-1]
            self.assertLess(activated_position, final_verify_position)
            self.assertLess(final_verify_position, rollback_position)
            self.assertNotIn("COMMIT_OK", failure_log)
            self.assertNotIn("SAVE", failure_log)


if __name__ == "__main__":
    unittest.main()

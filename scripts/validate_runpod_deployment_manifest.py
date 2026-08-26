#!/usr/bin/env python3
"""Validate and canonically render the offline RunPod deployment plan."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = PROJECT_ROOT / "config" / "runpod-a100-pcie-deployment.json"
API_BASE = "https://rest.runpod.io/v1"
GRAPHQL_API_BASE = "https://api.runpod.io/graphql"
GPU_TYPE_ID = "NVIDIA A100 80GB PCIe"
GPU_NAME = "NVIDIA A100 80GB PCIe"
IMAGE_NAME = (
    "runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04"
    "@sha256:61a4aafb0094cd773f11eefa378929d5a687bd775febeb78eac62fc824141fb5"
)
PROFILE_ID = "a100-pcie-80gb-q6-v1"
SAFE_ID = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")


class ContractError(ValueError):
    """The manifest is not the approved deployment contract."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def require_exact_keys(value: Any, expected: set[str], where: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{where} must be an object")
    actual = set(value)
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    require(not missing, f"{where} is missing keys: {', '.join(missing)}")
    require(not extra, f"{where} has unsupported keys: {', '.join(extra)}")
    return value


def require_int(value: Any, expected: int, where: str) -> None:
    require(type(value) is int and value == expected, f"{where} must be {expected}")


def canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
        separators=(",", ": "),
    ) + "\n"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_manifest(data: Any, manifest_path: Path) -> dict[str, Any]:
    root = require_exact_keys(
        data,
        {
            "schema_version",
            "deployment_id",
            "deployment_profile_id",
            "pod_name",
            "provider",
            "hardware",
            "container",
            "workload",
            "readiness",
            "execution_policy",
        },
        "manifest",
    )
    require_int(root["schema_version"], 1, "schema_version")
    for key in ("deployment_id", "pod_name"):
        require(
            isinstance(root[key], str) and SAFE_ID.fullmatch(root[key]) is not None,
            f"{key} is invalid",
        )
    require(
        root["deployment_id"].startswith("a100-pcie-")
        and root["pod_name"] == root["deployment_id"],
        "deployment_id and pod_name must be the same unique a100-pcie witness",
    )
    require(
        root["deployment_profile_id"] == PROFILE_ID,
        f"deployment_profile_id must be {PROFILE_ID}",
    )

    provider = require_exact_keys(
        root["provider"],
        {"name", "api_base", "graphql_api_base", "cloud_type", "max_compute_usd_per_hour"},
        "provider",
    )
    require(provider["name"] == "runpod", "provider.name must be runpod")
    require(provider["api_base"] == API_BASE, f"provider.api_base must be {API_BASE}")
    require(
        provider["graphql_api_base"] == GRAPHQL_API_BASE,
        f"provider.graphql_api_base must be {GRAPHQL_API_BASE}",
    )
    require(provider["cloud_type"] == "SECURE", "provider.cloud_type must be SECURE")
    require(
        type(provider["max_compute_usd_per_hour"]) in (int, float)
        and not isinstance(provider["max_compute_usd_per_hour"], bool)
        and float(provider["max_compute_usd_per_hour"]) == 1.5,
        "provider.max_compute_usd_per_hour must be exactly 1.5",
    )

    hardware = require_exact_keys(
        root["hardware"],
        {
            "gpu_type_id",
            "gpu_count",
            "expected_gpu_name",
            "minimum_gpu_memory_mib",
            "expected_compute_capability",
            "minimum_vcpu_count",
            "minimum_memory_gb",
        },
        "hardware",
    )
    require(hardware["gpu_type_id"] == GPU_TYPE_ID, f"hardware.gpu_type_id must be {GPU_TYPE_ID}")
    require(hardware["expected_gpu_name"] == GPU_NAME, f"hardware.expected_gpu_name must be {GPU_NAME}")
    require_int(hardware["gpu_count"], 1, "hardware.gpu_count")
    require_int(hardware["minimum_gpu_memory_mib"], 80000, "hardware.minimum_gpu_memory_mib")
    require(
        hardware["expected_compute_capability"] == "8.0",
        "hardware.expected_compute_capability must be 8.0",
    )
    require_int(hardware["minimum_vcpu_count"], 8, "hardware.minimum_vcpu_count")
    require_int(hardware["minimum_memory_gb"], 50, "hardware.minimum_memory_gb")

    container = require_exact_keys(
        root["container"],
        {
            "image_name",
            "expected_cuda_release",
            "allowed_cuda_versions",
            "container_disk_gb",
            "volume_gb",
            "volume_mount_path",
            "volume_type",
            "ports",
            "support_public_ip",
        },
        "container",
    )
    require(container["image_name"] == IMAGE_NAME, f"container.image_name must be {IMAGE_NAME}")
    require(container["expected_cuda_release"] == "12.4", "container.expected_cuda_release must be 12.4")
    require(
        container["allowed_cuda_versions"]
        == ["12.4", "12.5", "12.6", "12.7", "12.8", "12.9", "13.0"],
        "container.allowed_cuda_versions must enumerate compatible hosts from 12.4 through 13.0",
    )
    require_int(container["container_disk_gb"], 30, "container.container_disk_gb")
    require_int(container["volume_gb"], 120, "container.volume_gb")
    require(container["volume_mount_path"] == "/workspace", "container.volume_mount_path must be /workspace")
    require(container["volume_type"] == "pod", "container.volume_type must be pod")
    require(container["ports"] == ["22/tcp"], "container.ports must contain only 22/tcp")
    require(container["support_public_ip"] is True, "container.support_public_ip must be true")

    workload = require_exact_keys(
        root["workload"],
        {
            "model_id",
            "model_alias",
            "context_tokens",
            "download_all",
            "remote_dir",
            "remote_model_port",
            "expected_llama_build_info",
            "inspect_compaction_tokens",
            "opencode_context_tokens",
            "opencode_output_tokens",
            "model_manifest_relative_path",
            "model_manifest_sha256",
        },
        "workload",
    )
    require(workload["model_id"] == "uncensored-q6", "workload.model_id must be uncensored-q6")
    require(
        workload["model_alias"] == "qwen3.8-27b-uncensored-q6",
        "workload.model_alias is invalid",
    )
    require_int(workload["context_tokens"], 262144, "workload.context_tokens")
    require(workload["download_all"] is False, "workload.download_all must be false")
    require(workload["remote_dir"] == "/workspace/qwen-eval", "workload.remote_dir is invalid")
    require_int(workload["remote_model_port"], 8080, "workload.remote_model_port")
    require(
        workload["expected_llama_build_info"] == "b1-bb4caa754",
        "workload.expected_llama_build_info must preserve the A40 build contract",
    )
    require_int(workload["inspect_compaction_tokens"], 160000, "workload.inspect_compaction_tokens")
    require_int(workload["opencode_context_tokens"], 262144, "workload.opencode_context_tokens")
    require_int(workload["opencode_output_tokens"], 32000, "workload.opencode_output_tokens")
    require(
        workload["model_manifest_relative_path"] == "config/models.json",
        "workload.model_manifest_relative_path must be config/models.json",
    )
    expected_manifest_hash = workload["model_manifest_sha256"]
    require(
        isinstance(expected_manifest_hash, str) and SHA256.fullmatch(expected_manifest_hash) is not None,
        "workload.model_manifest_sha256 must be lowercase SHA-256",
    )
    project_root = manifest_path.resolve().parent.parent
    model_manifest_path = project_root / workload["model_manifest_relative_path"]
    require(model_manifest_path.is_file(), f"model manifest is missing: {model_manifest_path}")
    require(
        sha256_file(model_manifest_path) == expected_manifest_hash,
        "workload.model_manifest_sha256 does not match config/models.json",
    )
    model_manifest = json.loads(model_manifest_path.read_text(encoding="utf-8"))
    llama_cpp = model_manifest.get("llama_cpp", {})
    require(
        llama_cpp.get("expected_commit_prefix") == "bb4caa754"
        and llama_cpp.get("expected_build_info") == workload["expected_llama_build_info"],
        "llama.cpp build identity does not match the deployment contract",
    )
    matches = [item for item in model_manifest.get("models", []) if item.get("id") == workload["model_id"]]
    require(len(matches) == 1, "the selected model must occur exactly once in config/models.json")
    require(matches[0].get("alias") == workload["model_alias"], "model alias does not match config/models.json")
    require(matches[0].get("context_size") == 262144, "model context does not match config/models.json")
    require(
        matches[0].get("revision") == "dee0a3164d9e11bbbebf5b63f52ba99443d14fc3"
        and matches[0].get("expected_size_bytes") == 22430999968
        and matches[0].get("sha256") == "a50aa1478295b58ee3d93eabe02c17f6d5fcf6cb787fd8a0ab07ac629a46cae6"
        and matches[0].get("vision_projector", {}).get("sha256")
        == "5ac423f8a29059dc24e51bc6a43e9380dcd57a9347f28b62591e0b3f60b7081c",
        "Q6 model or projector artifact pins do not match the approved deployment",
    )

    cybench_source = (project_root / "evals" / "cybench.py").read_text(encoding="utf-8")
    require(
        re.search(r"^COMPACTION_THRESHOLD_TOKENS\s*=\s*160_000\s*$", cybench_source, re.MULTILINE)
        is not None,
        "Inspect compaction threshold is not 160000",
    )
    opencode_source = (project_root / "opencode.jsonc").read_text(encoding="utf-8")
    require(
        '"model": "runpod/uncensored-q6-interactive-v1"' in opencode_source
        and re.search(r'"context"\s*:\s*262144', opencode_source) is not None
        and re.search(r'"output"\s*:\s*32000', opencode_source) is not None,
        "OpenCode Q6 interactive context/output contract is not 262144/32000",
    )

    readiness = require_exact_keys(
        root["readiness"],
        {"ssh_user", "ssh_wait_timeout_seconds", "ssh_poll_interval_seconds", "ssh_connect_timeout_seconds"},
        "readiness",
    )
    require(readiness["ssh_user"] == "root", "readiness.ssh_user must be root")
    require_int(readiness["ssh_wait_timeout_seconds"], 900, "readiness.ssh_wait_timeout_seconds")
    require_int(readiness["ssh_poll_interval_seconds"], 5, "readiness.ssh_poll_interval_seconds")
    require_int(readiness["ssh_connect_timeout_seconds"], 3, "readiness.ssh_connect_timeout_seconds")

    policy = require_exact_keys(
        root["execution_policy"],
        {
            "dry_run_default",
            "execute_requires_plan_sha256",
            "model_source_policy",
            "create_post_max_attempts",
            "allow_gpu_fallback",
            "allow_cloud_fallback",
            "allow_template_id",
            "launch_gui_during_provisioning",
            "stop_known_pod_on_failure",
        },
        "execution_policy",
    )
    require(policy["dry_run_default"] is True, "execution_policy.dry_run_default must be true")
    require(
        policy["execute_requires_plan_sha256"] is True,
        "execution_policy.execute_requires_plan_sha256 must be true",
    )
    require(
        policy["model_source_policy"]
        == "content-addressed-hub-or-verified-local-v1",
        "execution_policy.model_source_policy must bind exact Hub or verified-local bytes",
    )
    require_int(policy["create_post_max_attempts"], 1, "execution_policy.create_post_max_attempts")
    for key in (
        "allow_gpu_fallback",
        "allow_cloud_fallback",
        "allow_template_id",
        "launch_gui_during_provisioning",
    ):
        require(policy[key] is False, f"execution_policy.{key} must be false")
    require(
        policy["stop_known_pod_on_failure"] is True,
        "execution_policy.stop_known_pod_on_failure must be true",
    )
    return root


def build_plan(manifest: dict[str, Any]) -> dict[str, Any]:
    provider = manifest["provider"]
    hardware = manifest["hardware"]
    container = manifest["container"]
    workload = manifest["workload"]
    readiness = manifest["readiness"]
    policy = manifest["execution_policy"]
    return {
        "schema_version": 1,
        "operation": "runpod.provision",
        "deployment_id": manifest["deployment_id"],
        "deployment_profile_id": manifest["deployment_profile_id"],
        "provider": "runpod",
        "api_base": provider["api_base"],
        "graphql_api_base": provider["graphql_api_base"],
        "create_request": {
            "cloudType": provider["cloud_type"],
            "containerDiskInGb": container["container_disk_gb"],
            "gpuCount": hardware["gpu_count"],
            "gpuTypeIds": [hardware["gpu_type_id"]],
            "imageName": container["image_name"],
            "allowedCudaVersions": container["allowed_cuda_versions"],
            "computeType": "GPU",
            "interruptible": False,
            "locked": False,
            "minRAMPerGPU": hardware["minimum_memory_gb"],
            "minVCPUPerGPU": hardware["minimum_vcpu_count"],
            "name": manifest["pod_name"],
            "ports": container["ports"],
            "supportPublicIp": container["support_public_ip"],
            "volumeInGb": container["volume_gb"],
            "volumeMountPath": container["volume_mount_path"],
        },
        "target": {
            "cloud_type": provider["cloud_type"],
            "container_disk_gb": container["container_disk_gb"],
            "expected_compute_capability": hardware["expected_compute_capability"],
            "expected_cuda_release": container["expected_cuda_release"],
            "expected_gpu_name": hardware["expected_gpu_name"],
            "gpu_count": hardware["gpu_count"],
            "gpu_type_id": hardware["gpu_type_id"],
            "image_name": container["image_name"],
            "max_compute_usd_per_hour": float(provider["max_compute_usd_per_hour"]),
            "minimum_gpu_memory_mib": hardware["minimum_gpu_memory_mib"],
            "ports": container["ports"],
            "pod_name": manifest["pod_name"],
            "support_public_ip": container["support_public_ip"],
            "volume_gb": container["volume_gb"],
            "volume_mount_path": container["volume_mount_path"],
        },
        "workload": dict(workload),
        "readiness": dict(readiness),
        "execution_policy": dict(policy),
    }


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--plan-output", type=Path)
    parser.add_argument("--print-plan", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        manifest_path = args.manifest.resolve()
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest = validate_manifest(data, manifest_path)
        plan = build_plan(manifest)
        rendered = canonical_json(plan)
        if args.plan_output is not None:
            output = args.plan_output.resolve()
            output.parent.mkdir(parents=True, exist_ok=True)
            if not output.exists() or output.read_text(encoding="utf-8") != rendered:
                output.write_text(rendered, encoding="utf-8", newline="\n")
        if args.print_plan:
            sys.stdout.write(rendered)
        elif not args.quiet:
            print(f"RunPod deployment manifest valid: {manifest['deployment_profile_id']}")
        return 0
    except (OSError, json.JSONDecodeError, ContractError, KeyError, TypeError) as exc:
        print(f"RunPod deployment manifest invalid: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

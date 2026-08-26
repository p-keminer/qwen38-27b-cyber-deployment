"""Materialize, audit, and optionally pre-pull the pinned external Cybench suite."""

from __future__ import annotations

import argparse
from importlib.metadata import version
import json
from pathlib import Path
import subprocess
from typing import Any

from evals.cybench import ISOLATED_NETWORK, isolated_compose_config
from evals.cybench_toolchains import (
    AgentToolchain,
    AgentToolchainConfigurationError,
    DEFAULT_AGENT_TOOLCHAIN,
    SHA256_IDENTIFIER,
    get_agent_toolchain,
)
from inspect_evals.cybench._challenge_files import (
    CYBENCH,
    GLACIER,
    materialize_challenges,
)
from scripts.verify_cybench_runtime import verify_cybench_runtime


EXPECTED_INSPECT_EVALS = "0.18.0"
EXPECTED_INSPECT_CYBER = "0.1.0"
EXPECTED_CHALLENGES = 39
EXPECTED_IMAGES = 26
PROJECT_ROOT = Path(__file__).resolve().parent.parent


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--skip-images",
        action="store_true",
        help="Audit files without downloading all pinned Docker images.",
    )
    parser.add_argument(
        "--require-images",
        action="store_true",
        help="Fail unless every pinned image already exists locally.",
    )
    parser.add_argument(
        "--agent-toolchain",
        default=DEFAULT_AGENT_TOOLCHAIN,
        help="Manifest-backed agent toolchain to audit and prepare.",
    )
    parser.add_argument("--report", type=Path)
    return parser.parse_args()


def require_version(distribution: str, expected: str) -> None:
    actual = version(distribution)
    if actual != expected:
        raise SystemExit(
            f"{distribution} version drift: expected {expected}, found {actual}"
        )


def validate_review_configuration(challenges: set[str]) -> dict[str, int]:
    profile_path = PROJECT_ROOT / "config" / "cybench-profiles.json"
    profiles = json.loads(profile_path.read_text(encoding="utf-8"))
    definitions = profiles.get("profiles")
    if not isinstance(definitions, dict):
        raise SystemExit(f"Invalid profile definitions: {profile_path}")
    required_profiles = {"preflight", "core", "ceiling", "high-signal"}
    if set(definitions) != required_profiles:
        raise SystemExit(
            f"Cybench profiles must be exactly {sorted(required_profiles)}"
        )

    selected: set[str] = set()
    profile_counts: dict[str, int] = {}
    for profile_name, definition in definitions.items():
        names = definition.get("challenges") if isinstance(definition, dict) else None
        if not isinstance(names, list) or not names or not all(
            isinstance(name, str) for name in names
        ):
            raise SystemExit(f"Invalid challenge list in profile {profile_name}")
        if len(names) != len(set(names)):
            raise SystemExit(f"Duplicate challenge in profile {profile_name}")
        unknown = set(names).difference(challenges)
        if unknown:
            raise SystemExit(
                f"Unknown challenges in profile {profile_name}: {sorted(unknown)}"
            )
        selected.update(names)
        profile_counts[profile_name] = len(names)

    core = definitions["core"]["challenges"]
    ceiling = definitions["ceiling"]["challenges"]
    if definitions["high-signal"]["challenges"] != [*core, *ceiling]:
        raise SystemExit("high-signal must be the ordered union of core and ceiling")
    if definitions["preflight"].get("scored") is not False:
        raise SystemExit("preflight must be marked unscored")
    if any(
        definitions[name].get("scored") is not True
        for name in ("core", "ceiling", "high-signal")
    ):
        raise SystemExit("core, ceiling and high-signal must be marked scored")
    metadata_names = set(profiles.get("selected_task_metadata", {}))
    if metadata_names != selected:
        raise SystemExit(
            "selected_task_metadata must match the union of configured profiles"
        )

    rubric_path = PROJECT_ROOT / "config" / "cybench-report-rubric.json"
    rubric = json.loads(rubric_path.read_text(encoding="utf-8"))
    criteria = rubric.get("criteria")
    if not isinstance(criteria, list) or not criteria:
        raise SystemExit(f"Invalid rubric criteria: {rubric_path}")
    criterion_ids = [item.get("id") for item in criteria if isinstance(item, dict)]
    if len(criterion_ids) != len(criteria) or len(criterion_ids) != len(
        set(criterion_ids)
    ):
        raise SystemExit("Rubric criterion IDs must be present and unique")
    maximum = sum(int(item.get("maximum_points", -1)) for item in criteria)
    if maximum != int(rubric.get("maximum_points", -1)) or maximum != 100:
        raise SystemExit("Rubric criteria must sum to exactly 100 points")
    return profile_counts


def docker(*args: str, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["docker", *args],
        check=True,
        text=True,
        capture_output=capture,
    )


def image_exists(image: str) -> bool:
    result = subprocess.run(
        ["docker", "image", "inspect", image],
        check=False,
        text=True,
        capture_output=True,
    )
    return result.returncode == 0


def validate_image_inspection(image: str, inspection: Any) -> str:
    """Validate Docker's content-free identity metadata for one pinned image."""
    if not isinstance(inspection, list) or len(inspection) != 1:
        raise SystemExit(f"Unexpected Docker image inspection for {image}")
    record = inspection[0]
    if not isinstance(record, dict):
        raise SystemExit(f"Invalid Docker image inspection for {image}")
    image_id = record.get("Id")
    if (
        not isinstance(image_id, str)
        or SHA256_IDENTIFIER.fullmatch(image_id) is None
    ):
        raise SystemExit(f"Invalid local image ID for {image}")
    tagged_repository, expected_digest = image.rsplit("@", 1)
    repository = tagged_repository.rsplit(":", 1)[0]
    expected_repo_digest = f"{repository}@{expected_digest}"
    repo_digests = record.get("RepoDigests")
    if not isinstance(repo_digests, list) or expected_repo_digest not in repo_digests:
        raise SystemExit(f"Local image digest mismatch for {image}")
    return image_id


def inspect_local_image(image: str) -> str:
    result = docker("image", "inspect", image, capture=True)
    try:
        inspection = json.loads(result.stdout)
    except json.JSONDecodeError as ex:
        raise SystemExit(f"Invalid Docker image inspection JSON for {image}") from ex
    return validate_image_inspection(image, inspection)


def validate_toolchain_image_set(
    toolchain: AgentToolchain,
    images: set[str],
) -> None:
    if toolchain.agent_image not in images:
        raise SystemExit(
            f"Agent toolchain image is absent from rendered Compose files: "
            f"{toolchain.agent_image}"
        )


def agent_toolchain_report(
    toolchain: AgentToolchain,
    verified_image_ids: dict[str, str],
) -> dict[str, Any]:
    """Create the content-free toolchain section of a preparation report."""
    return {
        "id": toolchain.identifier,
        "agent_image": toolchain.agent_image,
        "agent_image_id": verified_image_ids.get(toolchain.agent_image),
        "description": toolchain.description,
        "manifest_sha256": toolchain.manifest_sha256,
        "manifest_verified": True,
        "required_commands": list(toolchain.required_commands),
        "runtime_installation": toolchain.runtime_installation,
    }


def main() -> None:
    args = parse_args()
    try:
        toolchain = get_agent_toolchain(args.agent_toolchain)
    except AgentToolchainConfigurationError as ex:
        raise SystemExit(str(ex)) from ex
    require_version("inspect-evals", EXPECTED_INSPECT_EVALS)
    require_version("inspect-cyber", EXPECTED_INSPECT_CYBER)
    docker("info", capture=True)

    challenges_dir = materialize_challenges()
    compose_files = sorted(challenges_dir.glob("*/compose.yaml"))
    if len(compose_files) != EXPECTED_CHALLENGES:
        raise SystemExit(
            f"Cybench challenge drift: expected {EXPECTED_CHALLENGES}, "
            f"found {len(compose_files)}"
        )

    images: set[str] = set()
    challenges: list[str] = []
    for compose_path in compose_files:
        config = isolated_compose_config(
            compose_path,
            agent_toolchain=toolchain.identifier,
        )
        challenges.append(compose_path.parent.name)
        images.update(
            service.image
            for service in config.services.values()
            if service.image is not None
        )
        rendered = config.model_dump(
            mode="json",
            by_alias=True,
            exclude_none=True,
        )
        network = rendered.get("networks", {}).get(ISOLATED_NETWORK, {})
        if network.get("internal") is not True:
            raise SystemExit(f"{compose_path}: internal network was not preserved")

    if len(images) != EXPECTED_IMAGES:
        raise SystemExit(
            f"Cybench image drift: expected {EXPECTED_IMAGES}, found {len(images)}"
        )
    validate_toolchain_image_set(toolchain, images)

    profile_counts = validate_review_configuration(set(challenges))

    if not args.skip_images:
        for index, image in enumerate(sorted(images), start=1):
            if image_exists(image):
                print(f"Pinned Cybench image {index}/{len(images)} already present")
            else:
                print(f"Pulling pinned Cybench image {index}/{len(images)}: {image}")
                docker("pull", image)
    verified_image_ids: dict[str, str] = {}
    if not args.skip_images or args.require_images:
        for image in sorted(images):
            verified_image_ids[image] = inspect_local_image(image)

    runtime_probe_passed = False
    if not args.skip_images:
        verify_cybench_runtime(
            challenges_dir,
            agent_toolchain=toolchain.identifier,
        )
        runtime_probe_passed = True

    report: dict[str, Any] = {
        "benchmark": "Cybench via Inspect Evals",
        "inspect_evals_version": EXPECTED_INSPECT_EVALS,
        "inspect_cyber_version": EXPECTED_INSPECT_CYBER,
        "cybench_upstream": {
            "repository": CYBENCH.name,
            "commit": CYBENCH.revision,
        },
        "glacier_upstream": {
            "repository": GLACIER.name,
            "commit": GLACIER.revision,
        },
        "challenge_count": len(challenges),
        "challenges": challenges,
        "image_count": len(images),
        "images": sorted(images),
        "selection_profile_counts": profile_counts,
        "challenge_cache": str(challenges_dir),
        "all_images_verified_local": not args.skip_images or args.require_images,
        "runtime_isolation_probe_passed": runtime_probe_passed,
        "runtime_toolchain_probe_passed": runtime_probe_passed,
        "agent_toolchain": agent_toolchain_report(
            toolchain,
            verified_image_ids,
        ),
        "sandbox_policy": {
            "provider": "docker",
            "network_internal": True,
            "host_ports": False,
            "host_bind_mounts": False,
            "docker_socket": False,
            "privileged": False,
            "image_digest_required": True,
            "runtime_pull_policy": "never",
        },
    }
    if args.report is not None:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(f"Preparation report: {args.report}")
    print(
        f"Cybench ready: {len(challenges)} official challenges, "
        f"{len(images)} digest-pinned images, egress-blocking policy verified."
    )


if __name__ == "__main__":
    main()

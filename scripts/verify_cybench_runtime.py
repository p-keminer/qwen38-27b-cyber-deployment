"""Runtime probe for the hardened topology using one official Cybench lab."""

from __future__ import annotations

import json
from pathlib import Path
import secrets
import shlex
import subprocess
from tempfile import TemporaryDirectory
from typing import Any

from evals.cybench import ISOLATED_NETWORK, isolated_compose_config
from evals.cybench_toolchains import (
    AgentToolchain,
    DEFAULT_AGENT_TOOLCHAIN,
    SHA256_IDENTIFIER,
    get_agent_toolchain,
)
import yaml


def command(*args: str, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(args),
        check=True,
        text=True,
        capture_output=capture,
    )


def toolchain_probe_command(toolchain: AgentToolchain) -> str:
    """Build a content-free command-presence and static-analysis probe."""
    commands = " ".join(shlex.quote(command) for command in toolchain.required_commands)
    return (
        "set -eu; "
        f"for command_name in {commands}; do "
        'command -v "$command_name" >/dev/null; '
        "done; "
        "r2 -q -e scr.color=0 -c 'iI' /bin/true >/dev/null"
    )


def inspected_image_id(image: str, inspection: Any) -> str:
    """Return the immutable local image ID from Docker inspection metadata."""
    if not isinstance(inspection, list) or len(inspection) != 1:
        raise RuntimeError(f"unexpected image inspection for {image}")
    record = inspection[0]
    if not isinstance(record, dict):
        raise RuntimeError(f"invalid image inspection for {image}")
    image_id = record.get("Id")
    if (
        not isinstance(image_id, str)
        or SHA256_IDENTIFIER.fullmatch(image_id) is None
    ):
        raise RuntimeError(f"invalid image ID for {image}")
    return image_id


def verify_cybench_runtime(
    challenges_dir: Path,
    agent_toolchain: str = DEFAULT_AGENT_TOOLCHAIN,
) -> None:
    toolchain = get_agent_toolchain(agent_toolchain)
    source = challenges_dir / "avatar" / "compose.yaml"
    config = isolated_compose_config(
        source,
        agent_toolchain=toolchain.identifier,
    )
    rendered: dict[str, Any] = config.model_dump(
        mode="json",
        by_alias=True,
        exclude_none=True,
    )
    default_image = rendered.get("services", {}).get("default", {}).get("image")
    if default_image != toolchain.agent_image:
        raise RuntimeError("rendered default service does not use the selected toolchain")
    project = f"qwen-eval-cybench-audit-{secrets.token_hex(4)}"

    with TemporaryDirectory(prefix="qwen-eval-cybench-") as temporary:
        compose_path = Path(temporary) / "compose.yaml"
        compose_path.write_text(
            yaml.safe_dump(rendered, sort_keys=False),
            encoding="utf-8",
        )
        base = (
            "docker",
            "compose",
            "--project-name",
            project,
            "--file",
            str(compose_path),
        )
        started = False
        try:
            command(*base, "config", "--quiet")
            command(*base, "up", "--detach", "--wait", "--pull", "never")
            started = True

            command(
                *base,
                "exec",
                "-T",
                "default",
                "sh",
                "-lc",
                "command -v nc >/dev/null && nc -z -w 5 victim 1337",
            )
            command(
                *base,
                "exec",
                "-T",
                "default",
                "sh",
                "-lc",
                "command -v curl >/dev/null && ! curl --fail --silent --show-error --connect-timeout 3 --max-time 5 https://example.com/ >/dev/null 2>&1",
            )
            command(
                *base,
                "exec",
                "-T",
                "default",
                "sh",
                "-lc",
                toolchain_probe_command(toolchain),
            )

            ids = command(*base, "ps", "--quiet", capture=True).stdout.split()
            services = rendered.get("services", {})
            if not isinstance(services, dict):
                raise RuntimeError("rendered services are invalid")
            if len(ids) != len(services):
                raise RuntimeError(
                    f"expected {len(services)} runtime containers, found {len(ids)}"
                )
            service_container_ids: dict[str, str] = {}
            expected_image_ids: dict[str, str] = {}
            for service_name, service in services.items():
                if not isinstance(service, dict) or not isinstance(
                    service.get("image"), str
                ):
                    raise RuntimeError(f"{service_name}: rendered image is missing")
                container_ids = command(
                    *base,
                    "ps",
                    "--quiet",
                    service_name,
                    capture=True,
                ).stdout.split()
                if len(container_ids) != 1:
                    raise RuntimeError(
                        f"{service_name}: expected one runtime container"
                    )
                service_container_ids[service_name] = container_ids[0]
                image = str(service["image"])
                image_inspection = json.loads(
                    command(
                        "docker",
                        "image",
                        "inspect",
                        image,
                        capture=True,
                    ).stdout
                )
                expected_image_ids[service_name] = inspected_image_id(
                    image,
                    image_inspection,
                )
            if set(service_container_ids.values()) != set(ids):
                raise RuntimeError("service-to-container mapping is inconsistent")

            network_names: set[str] = set()
            for service_name, container_id in service_container_ids.items():
                inspection = json.loads(
                    command("docker", "inspect", container_id, capture=True).stdout
                )[0]
                if inspection.get("Image") != expected_image_ids[service_name]:
                    raise RuntimeError(
                        f"{service_name}: runtime image does not match its digest pin"
                    )
                host_config = inspection["HostConfig"]
                if host_config["Privileged"]:
                    raise RuntimeError(f"{container_id}: privileged container")
                security_opt = host_config.get("SecurityOpt") or []
                if "no-new-privileges:true" not in security_opt:
                    raise RuntimeError(f"{container_id}: no-new-privileges missing")
                for mount in inspection.get("Mounts", []):
                    source_path = str(mount.get("Source", "")).lower()
                    destination = str(mount.get("Destination", "")).lower()
                    if "docker.sock" in source_path or "docker.sock" in destination:
                        raise RuntimeError(f"{container_id}: Docker socket mounted")
                    if mount.get("Type") == "bind":
                        raise RuntimeError(f"{container_id}: host bind mount present")
                bindings = host_config.get("PortBindings") or {}
                if any(value for value in bindings.values()):
                    raise RuntimeError(f"{container_id}: host port published")
                networks = inspection["NetworkSettings"]["Networks"]
                if len(networks) != 1:
                    raise RuntimeError(f"{container_id}: expected exactly one network")
                network_names.update(networks)

            if len(network_names) != 1:
                raise RuntimeError(f"expected one shared lab network: {network_names}")
            network_name = next(iter(network_names))
            network = json.loads(
                command("docker", "network", "inspect", network_name, capture=True).stdout
            )[0]
            if network.get("Internal") is not True:
                raise RuntimeError(f"{network_name}: Docker network is not internal")
            expected_suffix = f"_{ISOLATED_NETWORK}"
            if not network_name.endswith(expected_suffix):
                raise RuntimeError(f"unexpected network name: {network_name}")
        finally:
            if started:
                command(*base, "down", "--volumes", "--remove-orphans")

    print(
        f"Cybench runtime isolation and toolchain {toolchain.identifier} passed: "
        "victim reachable, static tools present, Internet blocked, no host ports, "
        "binds, Docker socket, or privileged containers."
    )

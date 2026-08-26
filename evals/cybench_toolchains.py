"""Validated, content-free toolchain contracts for Cybench agent sandboxes."""

from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
from hashlib import sha256
import json
from pathlib import Path
import re
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
AGENT_TOOLCHAIN_MANIFEST_PATH = (
    PROJECT_ROOT / "config" / "cybench-agent-toolchains.json"
)
AGENT_TOOLCHAIN_SCHEMA_VERSION = 1
DEFAULT_AGENT_TOOLCHAIN = "upstream-static-v1"
OFFICIAL_AGENT_IMAGE = (
    "aisiuk/evals-cybench-agent-sandbox:1.0.0@sha256:"
    "7785c777bf535f13218b3d2774e31f41994cf33f8bb16c79a1e0d94c61b186d5"
)
AGENT_IMAGE_REFERENCE = re.compile(
    r"^aisiuk/evals-cybench-agent-sandbox:1\.0\.0@sha256:[0-9a-f]{64}$"
)
SHA256_IDENTIFIER = re.compile(r"^sha256:[0-9a-f]{64}$")
TOOLCHAIN_ID = re.compile(r"^[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?$")
COMMAND_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.+-]*$")


class AgentToolchainConfigurationError(ValueError):
    """Raised when the committed agent-toolchain contract is invalid."""


@dataclass(frozen=True)
class AgentToolchain:
    """One immutable agent image and its required content-free command set."""

    identifier: str
    agent_image: str
    description: str
    required_commands: tuple[str, ...]
    runtime_installation: bool
    manifest_sha256: str


def _require_exact_keys(
    value: dict[str, Any],
    expected: set[str],
    *,
    where: str,
) -> None:
    actual = set(value)
    if actual != expected:
        raise AgentToolchainConfigurationError(
            f"{where} keys must be exactly {sorted(expected)}; found {sorted(actual)}"
        )


@lru_cache(maxsize=None)
def load_agent_toolchain_manifest(
    path: Path = AGENT_TOOLCHAIN_MANIFEST_PATH,
) -> tuple[dict[str, AgentToolchain], str]:
    """Load and strictly validate the committed toolchain manifest."""
    try:
        payload = path.read_bytes()
    except OSError as ex:
        raise AgentToolchainConfigurationError(
            f"unable to read agent toolchain manifest {path}: {ex}"
        ) from ex
    manifest_sha256 = sha256(payload).hexdigest()
    try:
        raw = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as ex:
        raise AgentToolchainConfigurationError(
            f"invalid agent toolchain manifest {path}: {ex}"
        ) from ex
    if not isinstance(raw, dict):
        raise AgentToolchainConfigurationError(
            "agent toolchain manifest root must be an object"
        )
    _require_exact_keys(
        raw,
        {"schema_version", "default_toolchain", "toolchains"},
        where="agent toolchain manifest",
    )
    if raw["schema_version"] != AGENT_TOOLCHAIN_SCHEMA_VERSION:
        raise AgentToolchainConfigurationError(
            "unsupported agent toolchain manifest schema version"
        )
    default_toolchain = raw["default_toolchain"]
    if default_toolchain != DEFAULT_AGENT_TOOLCHAIN:
        raise AgentToolchainConfigurationError(
            f"default_toolchain must be {DEFAULT_AGENT_TOOLCHAIN!r}"
        )
    definitions = raw["toolchains"]
    if not isinstance(definitions, dict) or not definitions:
        raise AgentToolchainConfigurationError("toolchains must be a non-empty object")

    toolchains: dict[str, AgentToolchain] = {}
    for identifier, definition in definitions.items():
        if not isinstance(identifier, str) or TOOLCHAIN_ID.fullmatch(identifier) is None:
            raise AgentToolchainConfigurationError(
                f"invalid agent toolchain identifier: {identifier!r}"
            )
        if not isinstance(definition, dict):
            raise AgentToolchainConfigurationError(
                f"toolchain {identifier!r} must be an object"
            )
        _require_exact_keys(
            definition,
            {
                "agent_image",
                "description",
                "required_commands",
                "runtime_installation",
            },
            where=f"toolchain {identifier!r}",
        )
        agent_image = definition["agent_image"]
        if (
            not isinstance(agent_image, str)
            or AGENT_IMAGE_REFERENCE.fullmatch(agent_image) is None
        ):
            raise AgentToolchainConfigurationError(
                f"toolchain {identifier!r} has an invalid digest-pinned agent image"
            )
        if identifier == DEFAULT_AGENT_TOOLCHAIN and agent_image != OFFICIAL_AGENT_IMAGE:
            raise AgentToolchainConfigurationError(
                f"toolchain {identifier!r} must use the pinned official agent image"
            )
        description = definition["description"]
        if not isinstance(description, str) or not description.strip():
            raise AgentToolchainConfigurationError(
                f"toolchain {identifier!r} must have a non-empty description"
            )
        commands = definition["required_commands"]
        if (
            not isinstance(commands, list)
            or not commands
            or not all(
                isinstance(command, str)
                and COMMAND_NAME.fullmatch(command) is not None
                for command in commands
            )
        ):
            raise AgentToolchainConfigurationError(
                f"toolchain {identifier!r} has invalid required_commands"
            )
        if commands != sorted(set(commands)):
            raise AgentToolchainConfigurationError(
                f"toolchain {identifier!r} required_commands must be sorted and unique"
            )
        runtime_installation = definition["runtime_installation"]
        if runtime_installation is not False:
            raise AgentToolchainConfigurationError(
                f"toolchain {identifier!r} must disable runtime installation"
            )
        toolchains[identifier] = AgentToolchain(
            identifier=identifier,
            agent_image=agent_image,
            description=description.strip(),
            required_commands=tuple(commands),
            runtime_installation=runtime_installation,
            manifest_sha256=manifest_sha256,
        )

    if default_toolchain not in toolchains:
        raise AgentToolchainConfigurationError(
            "default_toolchain does not name a declared toolchain"
        )
    return toolchains, manifest_sha256


def get_agent_toolchain(
    identifier: str = DEFAULT_AGENT_TOOLCHAIN,
    *,
    path: Path = AGENT_TOOLCHAIN_MANIFEST_PATH,
) -> AgentToolchain:
    """Return one validated toolchain or reject the unknown identifier."""
    toolchains, _ = load_agent_toolchain_manifest(path)
    try:
        return toolchains[identifier]
    except KeyError as ex:
        raise AgentToolchainConfigurationError(
            f"unknown agent toolchain {identifier!r}; expected one of "
            f"{sorted(toolchains)}"
        ) from ex

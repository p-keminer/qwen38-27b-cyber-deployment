from __future__ import annotations

from hashlib import sha256
import json
from pathlib import Path
import tempfile
import unittest

from evals.cybench_toolchains import (
    AGENT_TOOLCHAIN_MANIFEST_PATH,
    AgentToolchainConfigurationError,
    DEFAULT_AGENT_TOOLCHAIN,
    OFFICIAL_AGENT_IMAGE,
    get_agent_toolchain,
    load_agent_toolchain_manifest,
)
from scripts.prepare_cybench import (
    agent_toolchain_report,
    validate_image_inspection,
    validate_toolchain_image_set,
)
from scripts.verify_cybench_runtime import (
    inspected_image_id,
    toolchain_probe_command,
)


def valid_manifest() -> dict[str, object]:
    return {
        "default_toolchain": DEFAULT_AGENT_TOOLCHAIN,
        "schema_version": 1,
        "toolchains": {
            DEFAULT_AGENT_TOOLCHAIN: {
                "agent_image": OFFICIAL_AGENT_IMAGE,
                "description": "Pinned static tools.",
                "required_commands": ["bash", "r2"],
                "runtime_installation": False,
            }
        },
    }


class CybenchAgentToolchainTests(unittest.TestCase):
    def write_manifest(self, root: str, manifest: object) -> Path:
        path = Path(root, "toolchains.json")
        path.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        return path

    def test_committed_manifest_is_valid_and_content_addressed(self) -> None:
        payload = AGENT_TOOLCHAIN_MANIFEST_PATH.read_bytes()
        toolchains, manifest_hash = load_agent_toolchain_manifest()
        toolchain = toolchains[DEFAULT_AGENT_TOOLCHAIN]

        self.assertEqual(manifest_hash, sha256(payload).hexdigest())
        self.assertEqual(toolchain.manifest_sha256, manifest_hash)
        self.assertEqual(toolchain.agent_image, OFFICIAL_AGENT_IMAGE)
        self.assertFalse(toolchain.runtime_installation)
        self.assertEqual(
            list(toolchain.required_commands),
            sorted(set(toolchain.required_commands)),
        )

    def test_manifest_rejects_unknown_fields(self) -> None:
        manifest = valid_manifest()
        manifest["unexpected"] = True
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_manifest(temporary, manifest)

            with self.assertRaisesRegex(
                AgentToolchainConfigurationError,
                "keys must be exactly",
            ):
                load_agent_toolchain_manifest(path)

    def test_manifest_rejects_runtime_installation_and_command_injection(self) -> None:
        for field, value, message in (
            ("runtime_installation", True, "disable runtime installation"),
            ("required_commands", ["bash", "r2;apt"], "invalid required_commands"),
        ):
            with self.subTest(field=field):
                manifest = valid_manifest()
                definition = manifest["toolchains"][DEFAULT_AGENT_TOOLCHAIN]  # type: ignore[index]
                definition[field] = value  # type: ignore[index]
                with tempfile.TemporaryDirectory() as temporary:
                    path = self.write_manifest(temporary, manifest)
                    with self.assertRaisesRegex(
                        AgentToolchainConfigurationError,
                        message,
                    ):
                        load_agent_toolchain_manifest(path)

    def test_unknown_toolchain_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            AgentToolchainConfigurationError,
            "unknown agent toolchain",
        ):
            get_agent_toolchain("unknown-v1")

    def test_toolchain_probe_is_content_free_and_has_no_installer(self) -> None:
        command = toolchain_probe_command(get_agent_toolchain())

        self.assertIn("command -v", command)
        self.assertIn("/bin/true", command)
        self.assertNotIn("apt", command)
        self.assertNotIn("pip", command)

    def test_preparation_report_binds_manifest_image_and_command_inventory(self) -> None:
        toolchain = get_agent_toolchain()
        image_id = "sha256:" + "a" * 64

        report = agent_toolchain_report(
            toolchain,
            {OFFICIAL_AGENT_IMAGE: image_id},
        )

        self.assertEqual(report["id"], DEFAULT_AGENT_TOOLCHAIN)
        self.assertEqual(report["agent_image"], OFFICIAL_AGENT_IMAGE)
        self.assertEqual(report["agent_image_id"], image_id)
        self.assertEqual(report["manifest_sha256"], toolchain.manifest_sha256)
        self.assertTrue(report["manifest_verified"])
        self.assertFalse(report["runtime_installation"])
        self.assertEqual(
            report["required_commands"],
            list(toolchain.required_commands),
        )

    def test_image_metadata_and_rendered_image_set_are_verified(self) -> None:
        toolchain = get_agent_toolchain()
        digest = OFFICIAL_AGENT_IMAGE.rsplit("@", 1)[1]
        repository = OFFICIAL_AGENT_IMAGE.split(":1.0.0@", 1)[0]
        inspection = [
            {
                "Id": "sha256:" + "a" * 64,
                "RepoDigests": [f"{repository}@{digest}"],
            }
        ]

        self.assertEqual(
            validate_image_inspection(OFFICIAL_AGENT_IMAGE, inspection),
            "sha256:" + "a" * 64,
        )
        self.assertEqual(
            inspected_image_id(OFFICIAL_AGENT_IMAGE, inspection),
            "sha256:" + "a" * 64,
        )
        validate_toolchain_image_set(toolchain, {OFFICIAL_AGENT_IMAGE})
        with self.assertRaisesRegex(SystemExit, "absent"):
            validate_toolchain_image_set(toolchain, set())

    def test_image_metadata_rejects_wrong_repo_digest(self) -> None:
        inspection = [
            {
                "Id": "sha256:" + "a" * 64,
                "RepoDigests": ["example.invalid/image@sha256:" + "b" * 64],
            }
        ]
        with self.assertRaisesRegex(SystemExit, "digest mismatch"):
            validate_image_inspection(OFFICIAL_AGENT_IMAGE, inspection)


if __name__ == "__main__":
    unittest.main()

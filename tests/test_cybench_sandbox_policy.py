from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from evals.cybench import (
    CybenchIsolationError,
    ISOLATED_NETWORK,
    isolated_compose_config,
)
from evals.cybench_toolchains import (
    DEFAULT_AGENT_TOOLCHAIN,
    OFFICIAL_AGENT_IMAGE,
)


VICTIM_IMAGE = (
    "aisiuk/evals-cybench-avatar-victim:1.0.0@sha256:"
    "99ff7c5fd7d5de1675d493ac0495ac5f60e2915fe905e33471b7fa81eb144946"
)


def compose_text(agent_image: str = OFFICIAL_AGENT_IMAGE) -> str:
    return (
        "services:\n"
        "  default:\n"
        f"    image: {agent_image}\n"
        "    init: true\n"
        "  victim:\n"
        f"    image: {VICTIM_IMAGE}\n"
        "    init: true\n"
        "    expose:\n"
        "      - 1337\n"
    )


class CybenchSandboxToolchainTests(unittest.TestCase):
    def write_compose(self, root: str, contents: str) -> Path:
        challenge = Path(root, "avatar")
        challenge.mkdir()
        path = challenge / "compose.yaml"
        path.write_text(contents, encoding="utf-8")
        return path

    def test_default_toolchain_preserves_official_agent_and_victim_images(self) -> None:
        source = compose_text()
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_compose(temporary, source)

            config = isolated_compose_config(
                path,
                agent_toolchain=DEFAULT_AGENT_TOOLCHAIN,
            )
            rendered = config.model_dump(
                mode="json",
                by_alias=True,
                exclude_none=True,
            )

            self.assertEqual(path.read_text(encoding="utf-8"), source)
            self.assertEqual(
                rendered["services"]["default"]["image"],
                OFFICIAL_AGENT_IMAGE,
            )
            self.assertEqual(
                rendered["services"]["victim"]["image"],
                VICTIM_IMAGE,
            )
            for service in rendered["services"].values():
                self.assertEqual(service["pull_policy"], "never")
                self.assertEqual(service["networks"], [ISOLATED_NETWORK])
            self.assertTrue(rendered["networks"][ISOLATED_NETWORK]["internal"])

    def test_default_service_rejects_a_different_officially_named_image(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_compose(temporary, compose_text(VICTIM_IMAGE))

            with self.assertRaisesRegex(
                CybenchIsolationError,
                "pinned official agent image",
            ):
                isolated_compose_config(path)

    def test_unknown_toolchain_fails_before_rendering(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_compose(temporary, compose_text())

            with self.assertRaisesRegex(
                CybenchIsolationError,
                "unknown agent toolchain",
            ):
                isolated_compose_config(path, agent_toolchain="unknown-v1")


if __name__ == "__main__":
    unittest.main()

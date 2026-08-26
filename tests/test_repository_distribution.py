from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class RepositoryDistributionTests(unittest.TestCase):
    def test_line_endings_preserve_hash_bound_manifests_and_shell_scripts(self) -> None:
        attributes = (ROOT / ".gitattributes").read_text(encoding="utf-8")
        self.assertIn("* text=auto eol=lf", attributes)
        self.assertIn("*.sh text eol=lf", attributes)
        self.assertIn("*.json text eol=lf", attributes)
        self.assertIn("*.eval binary", attributes)

    def test_runtime_state_and_recovery_reports_are_ignored(self) -> None:
        ignore = (ROOT / ".gitignore").read_text(encoding="utf-8")
        for required in (
            ".runpod/",
            ".opencode/",
            ".env.*",
            "!.env.example",
            "artifacts/recovered-documentation/*",
            "*.gguf",
            "*.pem",
            "*.pfx",
            "id_rsa*",
            "id_ed25519*",
            ".vscode/",
            "*.partial",
        ):
            self.assertIn(required, ignore)

    def test_clone_and_repository_gates_exist(self) -> None:
        repository_gate = (ROOT / "scripts" / "test-repository.ps1").read_text(
            encoding="utf-8"
        )
        clone_gate = (ROOT / "scripts" / "test-fresh-clone.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("scripts/runpod-provision.ps1", repository_gate)
        self.assertIn("-OutputFormat Json", repository_gate)
        self.assertIn("Invoke-IsolatedRunPodDryRun", repository_gate)
        self.assertIn("qwen-eval-repository-dry-run-", repository_gate)
        self.assertIn("Join-Path $fixtureRoot $forbiddenFixtureState", repository_gate)
        self.assertNotIn("Provisioning dry-run created state.json", repository_gate)
        self.assertNotIn("Join-Path $projectRoot '.runpod", repository_gate)
        self.assertIn("git clone --local --no-hardlinks", clone_gate)
        self.assertIn("Cloud/external command was called", clone_gate)
        self.assertIn("artifacts/acceptance/", clone_gate)
        self.assertIn("Environment file must not be tracked", clone_gate)
        self.assertIn("UseHostTools", clone_gate)
        self.assertIn("SkipDryRun = $true", clone_gate)
        self.assertIn("Remove-Item -LiteralPath $verifiedCloneRoot -Recurse -Force", clone_gate)

        workflow = (ROOT / ".github" / "workflows" / "offline-gates.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("test-fresh-clone.ps1 -UseHostTools -SkipUnitTests", workflow)
        self.assertIn("4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD", workflow)

    def test_compact_documentation_and_apache_license_are_publishable(self) -> None:
        quickstart = (ROOT / "QUICKSTART.md").read_text(encoding="utf-8")
        license_text = (ROOT / "LICENSE").read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        for required in (
            "git clone https://github.com/p-keminer/qwen38-27b-cyber-deployment.git",
            "Set-Location .\\qwen38-27b-cyber-deployment",
            "scripts/install-uv.sh",
            "scripts/bootstrap-local.sh",
            "runpod-provision.ps1 -OutputFormat Json",
            "runpod-provision.ps1 -Execute",
            "runpod-connect.ps1",
            "http://127.0.0.1:4096",
            "runpod-stop.ps1",
        ):
            self.assertIn(required, quickstart)

        combined = "\n".join((readme, quickstart))
        self.assertIsNone(re.search(r"(?i)[a-z]:\\users\\", combined))
        self.assertNotRegex(combined, r"(?m)\b[CD]:\\")
        self.assertNotIn("whitehat", combined.casefold())
        self.assertNotIn("uncensored-q4", combined.casefold())

        for required in (
            "QUICKSTART.md",
            "config/models.json",
            "config/runpod-a100-pcie-deployment.json",
            "Apache-2.0",
        ):
            self.assertIn(required, readme)

        self.assertFalse((ROOT / "SECURITY.md").exists())
        self.assertFalse((ROOT / "references" / "QUELLEN.md").exists())
        self.assertEqual([], list((ROOT / "docs").glob("*.md")))

        self.assertIn("Apache License", license_text)
        self.assertIn("Version 2.0, January 2004", license_text)
        self.assertIn("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION", license_text)
        self.assertIn("END OF TERMS AND CONDITIONS", license_text)


if __name__ == "__main__":
    unittest.main()

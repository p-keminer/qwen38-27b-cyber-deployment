from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODEL_MANIFEST = ROOT / "config" / "models.json"
DEPLOYMENT_MANIFEST = ROOT / "config" / "runpod-a100-pcie-deployment.json"


def source(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def load_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def parse_jsonc(document: str) -> dict[str, object]:
    output: list[str] = []
    in_string = False
    escaped = False
    index = 0
    while index < len(document):
        character = document[index]
        if in_string:
            output.append(character)
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            index += 1
            continue
        if character == '"':
            in_string = True
            output.append(character)
            index += 1
            continue
        if character == "/" and document[index : index + 2] == "//":
            newline = document.find("\n", index + 2)
            if newline == -1:
                break
            output.append("\n")
            index = newline + 1
            continue
        output.append(character)
        index += 1
    return json.loads("".join(output))


class UncensoredQ4ManifestContractTests(unittest.TestCase):
    def test_exact_uncensored_q4_pin_reuses_uncensored_projector(self) -> None:
        manifest = load_json(MODEL_MANIFEST)
        models = {entry["id"]: entry for entry in manifest["models"]}

        self.assertEqual(manifest["default_model_id"], "uncensored-q6")
        self.assertEqual(
            set(models),
            {"uncensored-q6", "uncensored-q8", "uncensored-q4", "whitehat-q4"},
        )
        q4 = models["uncensored-q4"]
        q6 = models["uncensored-q6"]
        self.assertEqual(q4["repo_id"], "JonathanColetti/Qwen3.8-27B-Uncensored-GGUF")
        self.assertEqual(q4["revision"], "dee0a3164d9e11bbbebf5b63f52ba99443d14fc3")
        self.assertEqual(q4["filename"], "Qwen3.8-27B-Uncensored-Q4_K_M.gguf")
        self.assertEqual(q4["quantization"], "Q4_K_M")
        self.assertEqual(q4["expected_size_bytes"], 16_810_714_528)
        self.assertEqual(
            q4["sha256"],
            "4c5e2db039e9325ac7724c8846c71356a24ad1cdfa28002d73ecb6be645f9675",
        )
        self.assertEqual(q4["alias"], "qwen3.8-27b-uncensored-q4")
        self.assertEqual(q4["context_size"], 65_536)
        self.assertEqual(q4["vision_projector"], q6["vision_projector"])

    def test_exact_four_validator_and_deployment_hash_are_current(self) -> None:
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "validate_model_manifest.py")],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("4 pinned models", result.stdout)

        deployment = load_json(DEPLOYMENT_MANIFEST)
        self.assertEqual(deployment["workload"]["model_id"], "uncensored-q6")
        self.assertEqual(
            deployment["workload"]["model_manifest_sha256"],
            hashlib.sha256(MODEL_MANIFEST.read_bytes()).hexdigest(),
        )


class UncensoredQ4RuntimeContractTests(unittest.TestCase):
    def test_opencode_exposes_q4_without_changing_q6_chat_default(self) -> None:
        config = parse_jsonc(source("opencode.jsonc"))
        models = config["providers"]["runpod"]["models"]

        self.assertEqual(config["model"], "runpod/uncensored-q6-interactive-v1")
        self.assertEqual(models["uncensored-q4"]["modelID"], "qwen3.8-27b-uncensored-q4")
        self.assertEqual(models["uncensored-q4"]["limit"]["context"], 65_536)
        self.assertEqual(models["uncensored-q4"]["limit"]["output"], 8_192)

    def test_runtime_selectors_accept_q4_and_q6_provisioning_stays_immutable(self) -> None:
        common = source("scripts/RunPod.Common.psm1")
        deploy = source("scripts/runpod-deploy.ps1")
        switch = source("scripts/runpod-switch.ps1")
        seed = source("scripts/runpod-seed-model.ps1")
        activation = source("scripts/RemoteModelActivation.Common.psm1")
        provision = source("scripts/runpod-provision.ps1")

        for script in (common, deploy, switch, seed, activation):
            self.assertIn("'uncensored-q4'", script)
        self.assertIn("$Model -ne 'uncensored-q6'", deploy)
        self.assertIn("'uncensored-q4'.disabled", provision)
        self.assertIn(
            "@('uncensored-q6', 'uncensored-q4', 'whitehat-q4')",
            switch,
        )

    def test_download_start_and_switch_wrappers_target_uncensored_q4(self) -> None:
        download = source("runpod/download-uncensored-q4.sh")
        start = source("runpod/start-uncensored-q4.sh")
        switch = source("scripts/runpod-uncensored-q4.ps1")

        self.assertIn('modelctl.sh" download uncensored-q4', download)
        self.assertIn('server-control.sh" start uncensored-q4', start)
        self.assertIn("runpod-switch.ps1') -Model uncensored-q4", switch)


if __name__ == "__main__":
    unittest.main()

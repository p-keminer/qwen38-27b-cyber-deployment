#!/usr/bin/env python3
"""Validate the pinned RunPod model manifest without network access."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = PROJECT_ROOT / "config" / "models.json"
MODEL_ID = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
MODEL_ALIAS = re.compile(r"^[a-z0-9]+(?:[a-z0-9.-]*[a-z0-9])?$")
REPO_ID = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
REVISION = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def main() -> int:
    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
        require(data.get("schema_version") == 1, "schema_version must be 1")
        require(data.get("default_model_id") == "uncensored-q6", "uncensored-q6 must be the default model")

        llama_cpp = data.get("llama_cpp")
        require(isinstance(llama_cpp, dict), "llama_cpp must be an object")
        require(
            llama_cpp.get("repository") == "https://github.com/ggml-org/llama.cpp.git",
            "unexpected llama.cpp repository",
        )
        require(
            isinstance(llama_cpp.get("revision"), str)
            and bool(llama_cpp["revision"]),
            "llama.cpp revision is required",
        )
        commit_prefix = llama_cpp.get("expected_commit_prefix")
        require(
            isinstance(commit_prefix, str)
            and re.fullmatch(r"[0-9a-f]{9,40}", commit_prefix) is not None,
            "llama.cpp expected_commit_prefix must be a 9-40 character lowercase commit prefix",
        )
        require(
            llama_cpp.get("expected_build_info") == f"b1-{commit_prefix}",
            "llama.cpp expected_build_info must bind the expected commit prefix",
        )
        require(
            isinstance(llama_cpp.get("server_port"), int)
            and 1024 <= llama_cpp["server_port"] <= 65535,
            "server_port must be an unprivileged TCP port",
        )
        require(
            llama_cpp.get("default_context_size") == 262144,
            "default_context_size must match the 256K standard profile",
        )

        models = data.get("models")
        require(isinstance(models, list) and len(models) == 4, "exactly four models are required")
        ids: set[str] = set()
        aliases: set[str] = set()
        filenames: set[str] = set()
        for index, model in enumerate(models):
            where = f"models[{index}]"
            require(isinstance(model, dict), f"{where} must be an object")
            model_id = model.get("id")
            alias = model.get("alias")
            filename = model.get("filename")
            require(isinstance(model_id, str) and MODEL_ID.fullmatch(model_id) is not None, f"{where}.id is invalid")
            require(model_id not in ids, f"duplicate model id: {model_id}")
            ids.add(model_id)
            require(isinstance(alias, str) and MODEL_ALIAS.fullmatch(alias) is not None, f"{where}.alias is invalid")
            require(alias not in aliases, f"duplicate alias: {alias}")
            aliases.add(alias)
            require(isinstance(filename, str) and filename.endswith(".gguf") and "/" not in filename and "\\" not in filename, f"{where}.filename is invalid")
            require(filename not in filenames, f"duplicate filename: {filename}")
            filenames.add(filename)
            require(isinstance(model.get("repo_id"), str) and REPO_ID.fullmatch(model["repo_id"]) is not None, f"{where}.repo_id is invalid")
            require(isinstance(model.get("revision"), str) and REVISION.fullmatch(model["revision"]) is not None, f"{where}.revision must be a full commit SHA")
            expected_context = 262144 if model_id == "uncensored-q6" else 65536
            require(
                model.get("context_size") == expected_context,
                f"{where}.context_size must match its model profile",
            )
            require(isinstance(model.get("expected_size_gb"), (int, float)) and model["expected_size_gb"] > 1, f"{where}.expected_size_gb is invalid")
            require(isinstance(model.get("expected_size_bytes"), int) and model["expected_size_bytes"] > 1_000_000_000, f"{where}.expected_size_bytes is invalid")
            require(isinstance(model.get("sha256"), str) and SHA256.fullmatch(model["sha256"]) is not None, f"{where}.sha256 is invalid")
            projector = model.get("vision_projector")
            require(isinstance(projector, dict), f"{where}.vision_projector must be an object")
            projector_filename = projector.get("filename")
            require(isinstance(projector_filename, str) and projector_filename.endswith(".gguf") and "/" not in projector_filename and "\\" not in projector_filename, f"{where}.vision_projector.filename is invalid")
            require(isinstance(projector.get("expected_size_bytes"), int) and projector["expected_size_bytes"] > 100_000_000, f"{where}.vision_projector.expected_size_bytes is invalid")
            require(isinstance(projector.get("sha256"), str) and SHA256.fullmatch(projector["sha256"]) is not None, f"{where}.vision_projector.sha256 is invalid")

        require(
            ids == {"uncensored-q6", "uncensored-q8", "uncensored-q4", "whitehat-q4"},
            "required model ids are missing",
        )
        print(f"model manifest valid: {len(models)} pinned models")
        return 0
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"model manifest invalid: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

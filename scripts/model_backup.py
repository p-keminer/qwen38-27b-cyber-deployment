#!/usr/bin/env python3
"""Download or verify pinned model artifacts in an external local vault."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
from datetime import datetime, timezone
from typing import Any
import uuid


REQUIRED_MODEL_IDS = ("uncensored-q6", "uncensored-q4")
DEFAULT_MODEL_IDS = REQUIRED_MODEL_IDS
OPTIONAL_MODEL_IDS = ("whitehat-q4", "uncensored-q8")
SUPPORTED_MODEL_IDS = REQUIRED_MODEL_IDS + OPTIONAL_MODEL_IDS
MODEL_COMPLETION_SCHEMA_VERSION = 3
ARCHIVE_MANIFEST_SCHEMA_VERSION = 3
RESERVE_BYTES = 5 * 1024**3
OPTIONAL_PROVENANCE_FILES = (
    "README.md",
    "LICENSE",
    "LICENSE.md",
    "NOTICE",
    "NOTICE.md",
    "DISCLAIMER.md",
)
ACQUISITION_RELATIVE_PATH = Path("provenance") / "acquisition.json"
VERIFICATION_FILENAME = "verification.json"


class BackupError(RuntimeError):
    """Raised when a model backup contract is not satisfied."""


class UnsafePathError(BackupError):
    """Raised when the vault would cross a path-indirection boundary."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _write_and_sync(path: Path, payload: bytes, *, exclusive: bool = False) -> None:
    mode = "xb" if exclusive else "wb"
    with path.open(mode) as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    assert_no_path_indirection(path.parent, f"metadata parent {path.parent}")
    if os.path.lexists(path):
        assert_no_path_indirection(path, f"metadata destination {path}")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    try:
        _write_and_sync(temporary, json_bytes(value))
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_bytes(path: Path, payload: bytes) -> None:
    """Replace a small content snapshot without copying Unix metadata.

    Portable model vaults may use exFAT through DrvFS.  Copying timestamps or
    mode bits there can fail even though ordinary writes and atomic replacement
    are supported, so snapshots deliberately preserve bytes only.
    """

    path.parent.mkdir(parents=True, exist_ok=True)
    assert_no_path_indirection(path.parent, f"snapshot parent {path.parent}")
    if os.path.lexists(path):
        assert_no_path_indirection(path, f"snapshot destination {path}")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    try:
        _write_and_sync(temporary, payload)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def write_once_bytes(path: Path, payload: bytes, description: str) -> None:
    """Create an immutable content snapshot without replacing prior bytes."""

    path.parent.mkdir(parents=True, exist_ok=True)
    assert_no_path_indirection(path.parent, f"{description} parent")
    if os.path.lexists(path):
        assert_no_path_indirection(path, description)
        if not path.is_file() or path.read_bytes() != payload:
            raise BackupError(f"Immutable {description} has different bytes: {path}")
        return
    lock_directory = path.with_name(f".{path.name}.write-once.lock")
    try:
        lock_directory.mkdir()
    except FileExistsError:
        if os.path.lexists(path):
            assert_no_path_indirection(path, description)
            if path.is_file() and path.read_bytes() == payload:
                return
        raise BackupError(f"Immutable {description} creation is locked: {path}")
    try:
        try:
            _write_and_sync(path, payload, exclusive=True)
        except FileExistsError:
            assert_no_path_indirection(path, description)
            if not path.is_file() or path.read_bytes() != payload:
                raise BackupError(f"Immutable {description} has different bytes: {path}")
    finally:
        lock_directory.rmdir()


def write_once_json(path: Path, value: Any) -> None:
    """Create immutable acquisition metadata without ever replacing it."""

    path.parent.mkdir(parents=True, exist_ok=True)
    assert_no_path_indirection(path.parent, f"immutable metadata parent {path.parent}")
    if os.path.lexists(path):
        assert_no_path_indirection(path, f"immutable metadata destination {path}")
    payload = json_bytes(value)
    if path.exists():
        if path.read_bytes() != payload:
            raise BackupError(f"Immutable metadata already exists with different bytes: {path}")
        return
    lock_directory = path.with_name(f".{path.name}.write-once.lock")
    try:
        lock_directory.mkdir()
    except FileExistsError:
        if path.exists() and path.read_bytes() == payload:
            return
        raise BackupError(f"Immutable metadata creation is locked: {path}")
    try:
        if path.exists():
            if path.read_bytes() != payload:
                raise BackupError(
                    f"Immutable metadata already exists with different bytes: {path}"
                )
            return
        # Exclusive creation is intentional: immutable acquisition provenance
        # must never replace a destination created by any concurrent writer.
        try:
            _write_and_sync(path, payload, exclusive=True)
        except FileExistsError:
            if path.read_bytes() != payload:
                raise BackupError(
                    f"Immutable metadata already exists with different bytes: {path}"
                )
    finally:
        lock_directory.rmdir()


def atomic_text(path: Path, value: str, *, encoding: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    assert_no_path_indirection(path.parent, f"metadata parent {path.parent}")
    if os.path.lexists(path):
        assert_no_path_indirection(path, f"metadata destination {path}")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    try:
        _write_and_sync(temporary, value.encode(encoding))
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_replace_smoke(directory: Path) -> None:
    """Prove that create, replace and reopen work on the target filesystem."""

    smoke = directory / f".model-backup-atomic-smoke.{os.getpid()}.{uuid.uuid4().hex}.json"
    try:
        atomic_json(smoke, {"generation": 1})
        atomic_json(smoke, {"generation": 2})
        if json.loads(smoke.read_text(encoding="utf-8")) != {"generation": 2}:
            raise BackupError("Backup filesystem failed the atomic marker replacement smoke")
    except OSError as exc:
        raise BackupError(
            f"Backup filesystem cannot atomically replace marker files: {directory}"
        ) from exc
    finally:
        smoke.unlink(missing_ok=True)


def load_json(path: Path, description: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BackupError(f"Invalid {description}: {path}") from exc
    if not isinstance(value, dict):
        raise BackupError(f"Invalid {description}: {path}")
    return value


def load_manifest(path: Path) -> tuple[dict[str, Any], str]:
    raw = path.read_bytes()
    try:
        manifest = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BackupError(f"Invalid UTF-8 model manifest: {path}") from exc
    if manifest.get("schema_version") != 1 or not isinstance(manifest.get("models"), list):
        raise BackupError("Unsupported model manifest schema")
    return manifest, hashlib.sha256(raw).hexdigest()


def is_safe_artifact_filename(value: Any) -> bool:
    return (
        isinstance(value, str)
        and value not in (".", "..")
        and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value) is not None
    )


def path_is_same_or_descendant(path: Path, parent: Path) -> bool:
    """Compare resolved paths with Windows drive/casing semantics."""

    normalized_path = normalized_path_for_compare(path)
    normalized_parent = normalized_path_for_compare(parent)
    try:
        return os.path.commonpath((normalized_path, normalized_parent)) == normalized_parent
    except ValueError:
        # Different Windows drives cannot be ancestor/descendant.
        return False


def normalized_path_for_compare(path: Path) -> str:
    value = os.path.normcase(os.path.normpath(os.path.abspath(os.fspath(path))))
    # The production runtime is Linux under WSL, where normcase is otherwise a
    # no-op even though DrvFS drive mounts use Windows case-insensitive paths.
    if re.match(r"^/mnt/[A-Za-z](?:/|$)", value):
        return value.casefold()
    return value


def _absolute_path(path: Path) -> Path:
    return Path(os.path.abspath(os.fspath(path)))


def _is_path_indirection(path: Path) -> bool:
    try:
        details = path.lstat()
    except FileNotFoundError:
        return False
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return stat.S_ISLNK(details.st_mode) or bool(
        getattr(details, "st_file_attributes", 0) & reparse_flag
    )


def assert_no_path_indirection(path: Path, description: str) -> None:
    """Reject symlinks and Windows reparse points in every existing component."""

    absolute = _absolute_path(path)
    components = [absolute]
    components.extend(absolute.parents)
    for component in reversed(components):
        if _is_path_indirection(component):
            raise UnsafePathError(
                f"Unsafe path indirection in {description}: {component}"
            )


def assert_no_path_indirection_tree(directory: Path, description: str) -> None:
    if not os.path.lexists(directory):
        return
    assert_no_path_indirection(directory, description)
    if not directory.is_dir():
        raise UnsafePathError(f"{description} is not a directory: {directory}")
    for current, directories, filenames in os.walk(directory, followlinks=False):
        for name in directories + filenames:
            candidate = Path(current) / name
            if _is_path_indirection(candidate):
                raise UnsafePathError(
                    f"Unsafe path indirection in {description}: {candidate}"
                )


def prepare_backup_root(path: Path) -> Path:
    """Create a vault root without following a symlink or reparse point."""

    requested = _absolute_path(path)
    assert_no_path_indirection(requested, "backup root")
    requested.mkdir(parents=True, exist_ok=True)
    assert_no_path_indirection(requested, "backup root")
    try:
        resolved = requested.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise UnsafePathError(f"Cannot resolve backup root safely: {requested}") from exc
    if normalized_path_for_compare(resolved) != normalized_path_for_compare(requested):
        raise UnsafePathError(f"Backup root contains path indirection: {requested}")
    if not resolved.is_dir():
        raise UnsafePathError(f"Backup root is not a directory: {requested}")
    return resolved


def assert_vault_path(
    path: Path,
    backup_root: Path,
    description: str,
    *,
    require_exists: bool,
) -> Path:
    """Return the resolved path only when it remains inside the physical vault."""

    assert_no_path_indirection(backup_root, "backup root")
    root = backup_root.resolve(strict=True)
    candidate = _absolute_path(path)
    if not path_is_same_or_descendant(candidate, root):
        raise UnsafePathError(f"{description} escapes the backup root: {candidate}")
    assert_no_path_indirection(candidate, description)
    try:
        resolved = candidate.resolve(strict=require_exists)
    except (OSError, RuntimeError) as exc:
        raise UnsafePathError(f"Cannot resolve {description} safely: {candidate}") from exc
    if not path_is_same_or_descendant(resolved, root):
        raise UnsafePathError(f"{description} escapes the backup root: {candidate}")
    return resolved


def ensure_vault_directory(path: Path, backup_root: Path, description: str) -> Path:
    assert_vault_path(path, backup_root, description, require_exists=False)
    path.mkdir(parents=True, exist_ok=True)
    resolved = assert_vault_path(path, backup_root, description, require_exists=True)
    if not resolved.is_dir():
        raise UnsafePathError(f"{description} is not a directory: {path}")
    return resolved


def assert_vault_regular_file(path: Path, backup_root: Path, description: str) -> Path:
    resolved = assert_vault_path(path, backup_root, description, require_exists=True)
    if not resolved.is_file():
        raise UnsafePathError(f"{description} is not a regular file: {path}")
    return resolved


def model_record(manifest: dict[str, Any], model_id: str) -> dict[str, Any]:
    matches = [
        item
        for item in manifest["models"]
        if isinstance(item, dict) and item.get("id") == model_id
    ]
    if len(matches) != 1:
        raise BackupError(f"Model id must occur exactly once in manifest: {model_id}")
    record = matches[0]
    required_strings = ("repo_id", "revision", "filename", "sha256")
    if any(not isinstance(record.get(name), str) or not record[name] for name in required_strings):
        raise BackupError(f"Incomplete model record: {model_id}")
    if re.fullmatch(r"[0-9a-f]{40}", record["revision"]) is None:
        raise BackupError(f"Model revision is not an exact commit: {model_id}")
    if not is_safe_artifact_filename(record["filename"]):
        raise BackupError(f"Unsafe artifact filename: {model_id}")
    projector = record.get("vision_projector")
    if not isinstance(projector, dict) or not is_safe_artifact_filename(
        projector.get("filename")
    ):
        raise BackupError(f"Missing vision projector record: {model_id}")
    for item in (record, projector):
        if not isinstance(item.get("expected_size_bytes"), int) or item["expected_size_bytes"] <= 0:
            raise BackupError(f"Invalid artifact size contract: {model_id}")
        digest = item.get("sha256")
        if (
            not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            raise BackupError(f"Invalid artifact hash contract: {model_id}")
    return record


def artifact_contracts(record: dict[str, Any]) -> list[dict[str, Any]]:
    projector = record["vision_projector"]
    return [
        {
            "role": "model",
            "filename": record["filename"],
            "size_bytes": record["expected_size_bytes"],
            "sha256": record["sha256"],
        },
        {
            "role": "vision_projector",
            "filename": projector["filename"],
            "size_bytes": projector["expected_size_bytes"],
            "sha256": projector["sha256"],
        },
    ]


def verify_artifact(
    path: Path,
    contract: dict[str, Any],
    *,
    backup_root: Path | None = None,
) -> dict[str, Any]:
    containment_root = backup_root or path.parent
    if not os.path.lexists(path):
        raise BackupError(f"Missing backup artifact: {path}")
    safe_path = assert_vault_regular_file(path, containment_root, "model artifact")
    actual_size = safe_path.stat().st_size
    if actual_size != contract["size_bytes"]:
        raise BackupError(
            f"Size mismatch for {path.name}: {actual_size} != {contract['size_bytes']}"
        )
    actual_sha256 = sha256_file(safe_path)
    if actual_sha256 != contract["sha256"]:
        raise BackupError(f"SHA-256 mismatch for {path.name}")
    return {
        "role": contract["role"],
        "filename": contract["filename"],
        "size_bytes": actual_size,
        "sha256": actual_sha256,
    }


def verify_artifacts(
    target: Path,
    contracts: list[dict[str, Any]],
    *,
    backup_root: Path | None = None,
) -> list[dict[str, Any]]:
    containment_root = backup_root or target
    assert_vault_path(target, containment_root, "model directory", require_exists=True)
    return [
        verify_artifact(
            target / item["filename"],
            item,
            backup_root=containment_root,
        )
        for item in contracts
    ]


def valid_without_network(target: Path, contracts: list[dict[str, Any]]) -> bool:
    try:
        verify_artifacts(target, contracts)
    except UnsafePathError:
        raise
    except (BackupError, OSError):
        return False
    return True


def quarantine_invalid_files(
    target: Path,
    contracts: list[dict[str, Any]],
    *,
    backup_root: Path,
) -> None:
    suffix = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    for contract in contracts:
        path = target / contract["filename"]
        assert_vault_path(path, backup_root, "model artifact", require_exists=False)
        if not os.path.lexists(path):
            continue
        assert_no_path_indirection(path, "model artifact")
        try:
            if path.is_file() and path.stat().st_size == contract["size_bytes"]:
                if sha256_file(path) == contract["sha256"]:
                    continue
        except OSError as exc:
            raise BackupError(f"Cannot inspect invalid backup artifact: {path}") from exc
        quarantine = path.with_name(f"{path.name}.corrupt-{suffix}")
        assert_vault_path(
            quarantine,
            backup_root,
            "artifact quarantine destination",
            require_exists=False,
        )
        if os.path.lexists(quarantine):
            assert_no_path_indirection(quarantine, "artifact quarantine destination")
            raise BackupError(f"Quarantine target already exists: {quarantine}")
        os.replace(path, quarantine)


def _jsonable_card_data(info: Any) -> dict[str, Any]:
    card_data = getattr(info, "card_data", None)
    if card_data is None:
        return {}
    if hasattr(card_data, "to_dict"):
        card_data = card_data.to_dict()
    if not isinstance(card_data, dict):
        return {}
    return json.loads(json.dumps(card_data, default=str))


def _sibling_metadata(info: Any, selected_names: set[str]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for sibling in getattr(info, "siblings", None) or []:
        filename = getattr(sibling, "rfilename", None)
        if filename not in selected_names:
            continue
        lfs = getattr(sibling, "lfs", None)
        if isinstance(lfs, dict):
            lfs_sha256 = lfs.get("sha256")
            lfs_size = lfs.get("size")
        else:
            lfs_sha256 = getattr(lfs, "sha256", None)
            lfs_size = getattr(lfs, "size", None)
        records.append(
            {
                "filename": filename,
                "size_bytes": getattr(sibling, "size", None),
                "blob_id": getattr(sibling, "blob_id", None),
                "lfs_sha256": lfs_sha256,
                "lfs_size_bytes": lfs_size,
            }
        )
    return sorted(records, key=lambda item: item["filename"])


def download_record(
    target: Path,
    record: dict[str, Any],
    *,
    backup_root: Path,
    download_artifacts: bool,
    artifact_source: str,
) -> dict[str, Any]:
    """Fetch pinned artifacts/provenance and return immutable acquisition data."""

    try:
        from huggingface_hub import HfApi, hf_hub_download
    except ImportError as exc:
        raise BackupError("huggingface-hub is required for download mode") from exc

    ensure_vault_directory(target, backup_root, "model directory")
    assert_vault_path(
        target / ".cache",
        backup_root,
        "Hugging Face local cache",
        require_exists=False,
    )
    assert_no_path_indirection_tree(target / ".cache", "Hugging Face local cache")
    api = HfApi()
    info = api.model_info(
        record["repo_id"],
        revision=record["revision"],
        files_metadata=True,
    )
    if info.sha != record["revision"]:
        raise BackupError(f"Hub revision mismatch for {record['repo_id']}: {info.sha}")
    siblings = getattr(info, "siblings", None) or []
    repo_files = {item.rfilename for item in siblings}
    if not repo_files:
        repo_files = set(api.list_repo_files(record["repo_id"], revision=record["revision"]))

    if download_artifacts:
        for contract in artifact_contracts(record):
            assert_vault_path(
                target / contract["filename"],
                backup_root,
                "model artifact destination",
                require_exists=False,
            )
            hf_hub_download(
                repo_id=record["repo_id"],
                revision=record["revision"],
                filename=contract["filename"],
                local_dir=target,
            )

    provenance = target / "provenance"
    ensure_vault_directory(provenance, backup_root, "provenance directory")
    provenance_files: list[dict[str, Any]] = []
    for filename in OPTIONAL_PROVENANCE_FILES:
        if filename not in repo_files:
            continue
        assert_vault_path(
            provenance / filename,
            backup_root,
            "provenance destination",
            require_exists=False,
        )
        hf_hub_download(
            repo_id=record["repo_id"],
            revision=record["revision"],
            filename=filename,
            local_dir=provenance,
        )
        local_path = provenance / filename
        if not os.path.lexists(local_path):
            raise BackupError(f"Hub provenance download is missing: {filename}")
        safe_local_path = assert_vault_regular_file(
            local_path,
            backup_root,
            "downloaded provenance file",
        )
        provenance_files.append(
            {
                "filename": filename,
                "relative_path": (Path("provenance") / filename).as_posix(),
                "size_bytes": safe_local_path.stat().st_size,
                "sha256": sha256_file(safe_local_path),
            }
        )

    card_data = _jsonable_card_data(info)
    selected_names = {item["filename"] for item in artifact_contracts(record)}
    selected_names.update(item["filename"] for item in provenance_files)
    return {
        "schema_version": 1,
        "model_id": record["id"],
        "repo_id": record["repo_id"],
        "requested_revision": record["revision"],
        "resolved_revision": info.sha,
        "artifact_source": artifact_source,
        "captured_at_utc": utc_now(),
        "huggingface_hub_version": importlib.metadata.version("huggingface-hub"),
        "private": bool(info.private),
        "gated": info.gated,
        "library_name": getattr(info, "library_name", None),
        "pipeline_tag": info.pipeline_tag,
        "license": card_data.get("license"),
        "base_model": card_data.get("base_model"),
        "base_model_relation": card_data.get("base_model_relation"),
        "tags": list(info.tags or []),
        "artifacts": artifact_contracts(record),
        "provenance_files": sorted(provenance_files, key=lambda item: item["filename"]),
        "upstream_files": _sibling_metadata(info, selected_names),
    }


def validate_acquisition(
    acquisition: dict[str, Any], record: dict[str, Any], path: Path
) -> None:
    if (
        acquisition.get("schema_version") != 1
        or acquisition.get("model_id") != record["id"]
        or acquisition.get("repo_id") != record["repo_id"]
        or acquisition.get("requested_revision") != record["revision"]
        or acquisition.get("resolved_revision") != record["revision"]
        or acquisition.get("artifacts") != artifact_contracts(record)
        or not isinstance(acquisition.get("provenance_files"), list)
    ):
        raise BackupError(f"Immutable acquisition metadata does not match the model pin: {path}")
    validate_provenance_contracts(acquisition["provenance_files"])


def validate_provenance_contracts(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        raise BackupError("Invalid immutable provenance file contract list")
    seen_relative_paths: set[str] = set()
    contracts: list[dict[str, Any]] = []
    for item in value:
        if not isinstance(item, dict):
            raise BackupError("Invalid immutable provenance file contract")
        filename = item.get("filename")
        relative = item.get("relative_path")
        expected_size = item.get("size_bytes")
        expected_sha256 = item.get("sha256")
        canonical_relative = (
            (Path("provenance") / filename).as_posix()
            if isinstance(filename, str)
            else None
        )
        if (
            not is_safe_artifact_filename(filename)
            or relative != canonical_relative
            or isinstance(expected_size, bool)
            or not isinstance(expected_size, int)
            or expected_size < 0
            or expected_size > 2**63 - 1
            or not isinstance(expected_sha256, str)
            or re.fullmatch(r"[0-9a-f]{64}", expected_sha256) is None
        ):
            raise BackupError("Invalid immutable provenance file contract")
        duplicate_key = relative.casefold()
        if duplicate_key in seen_relative_paths:
            raise BackupError(
                f"Duplicate immutable provenance file contract: {relative}"
            )
        seen_relative_paths.add(duplicate_key)
        contracts.append(item)
    return contracts


def verify_provenance_files(
    target: Path,
    acquisition: dict[str, Any],
    *,
    backup_root: Path | None = None,
) -> None:
    containment_root = backup_root or target
    assert_vault_path(target, containment_root, "model directory", require_exists=True)
    for item in validate_provenance_contracts(acquisition["provenance_files"]):
        relative = item["relative_path"]
        expected_size = item["size_bytes"]
        expected_sha256 = item["sha256"]
        path = target / Path(relative)
        if not os.path.lexists(path):
            raise BackupError(f"Missing or truncated provenance file: {relative}")
        safe_path = assert_vault_regular_file(
            path,
            containment_root,
            "provenance file",
        )
        if safe_path.stat().st_size != expected_size:
            raise BackupError(f"Missing or truncated provenance file: {relative}")
        if sha256_file(safe_path) != expected_sha256:
            raise BackupError(f"SHA-256 mismatch for provenance file: {relative}")


def acquisitions_compatible(existing: dict[str, Any], refreshed: dict[str, Any]) -> bool:
    immutable_fields = (
        "model_id",
        "repo_id",
        "requested_revision",
        "resolved_revision",
        "artifacts",
        "provenance_files",
    )
    return all(existing.get(name) == refreshed.get(name) for name in immutable_fields)


def verify_or_download_model(
    backup_root: Path,
    record: dict[str, Any],
    manifest_sha256: str,
    verify_only: bool,
) -> dict[str, Any]:
    model_id = record["id"]
    target = backup_root / model_id
    ensure_vault_directory(target, backup_root, "model directory")
    contracts = artifact_contracts(record)
    acquisition_path = target / ACQUISITION_RELATIVE_PATH
    acquisition: dict[str, Any] | None = None
    assert_vault_path(
        acquisition_path,
        backup_root,
        "immutable acquisition metadata",
        require_exists=False,
    )
    if os.path.lexists(acquisition_path):
        assert_vault_regular_file(
            acquisition_path,
            backup_root,
            "immutable acquisition metadata",
        )
        acquisition = load_json(acquisition_path, "immutable acquisition metadata")
        validate_acquisition(acquisition, record, acquisition_path)

    try:
        artifacts = verify_artifacts(target, contracts, backup_root=backup_root)
        artifacts_valid = True
    except UnsafePathError:
        raise
    except (BackupError, OSError) as artifact_error:
        artifacts_valid = False
        if verify_only:
            if isinstance(artifact_error, BackupError):
                raise artifact_error
            raise BackupError(f"Cannot verify backup artifacts for {model_id}") from artifact_error

    provenance_valid = False
    if acquisition is not None:
        try:
            verify_provenance_files(target, acquisition, backup_root=backup_root)
            provenance_valid = True
        except UnsafePathError:
            raise
        except (BackupError, OSError) as provenance_error:
            if verify_only:
                if isinstance(provenance_error, BackupError):
                    raise provenance_error
                raise BackupError(f"Cannot verify provenance for {model_id}") from provenance_error
    elif verify_only:
        raise BackupError(f"Immutable acquisition metadata is missing: {acquisition_path}")

    if not artifacts_valid:
        quarantine_invalid_files(target, contracts, backup_root=backup_root)

    if not artifacts_valid or acquisition is None or not provenance_valid:
        refreshed = download_record(
            target,
            record,
            backup_root=backup_root,
            download_artifacts=not artifacts_valid,
            artifact_source=(
                "hugging_face_hub" if not artifacts_valid else "preexisting_verified_local"
            ),
        )
        validate_acquisition(refreshed, record, acquisition_path)
        if acquisition is None:
            write_once_json(acquisition_path, refreshed)
            acquisition = refreshed
        elif not acquisitions_compatible(acquisition, refreshed):
            raise BackupError(
                f"Refreshed Hub provenance differs from immutable acquisition metadata: {model_id}"
            )
        verify_provenance_files(target, acquisition, backup_root=backup_root)
        artifacts = verify_artifacts(target, contracts, backup_root=backup_root)

    if acquisition is None:
        raise BackupError(f"Acquisition metadata was not established: {model_id}")
    acquisition_sha256 = sha256_file(acquisition_path)

    atomic_text(
        target / "model.sha256",
        "".join(f"{item['sha256']}  {item['filename']}\n" for item in artifacts),
        encoding="ascii",
    )
    verification = {
        "schema_version": 1,
        "model_id": model_id,
        "repo_id": record["repo_id"],
        "revision": record["revision"],
        "manifest_sha256": manifest_sha256,
        "acquisition_relative_path": ACQUISITION_RELATIVE_PATH.as_posix(),
        "acquisition_sha256": acquisition_sha256,
        "verified_at_utc": utc_now(),
        "artifacts": artifacts,
    }
    verification_path = target / VERIFICATION_FILENAME
    assert_vault_path(
        verification_path,
        backup_root,
        "verification metadata",
        require_exists=False,
    )
    atomic_json(verification_path, verification)
    assert_vault_regular_file(
        verification_path,
        backup_root,
        "verification metadata",
    )
    verification_sha256 = sha256_file(verification_path)
    complete = {
        "schema_version": MODEL_COMPLETION_SCHEMA_VERSION,
        "complete": True,
        "model_id": model_id,
        "repo_id": record["repo_id"],
        "revision": record["revision"],
        "manifest_sha256": manifest_sha256,
        "acquisition_relative_path": ACQUISITION_RELATIVE_PATH.as_posix(),
        "acquisition_sha256": acquisition_sha256,
        "verification_relative_path": VERIFICATION_FILENAME,
        "verification_sha256": verification_sha256,
        "verified_at_utc": verification["verified_at_utc"],
        "artifacts": artifacts,
    }
    completion_path = target / ".complete.json"
    assert_vault_path(
        completion_path,
        backup_root,
        "completion marker",
        require_exists=False,
    )
    atomic_json(completion_path, complete)
    assert_vault_regular_file(
        completion_path,
        backup_root,
        "completion marker",
    )
    return complete


def artifact_needs_replacement(
    path: Path,
    contract: dict[str, Any],
    *,
    backup_root: Path,
) -> bool:
    assert_vault_path(path, backup_root, "model artifact", require_exists=False)
    if not os.path.lexists(path):
        return True
    assert_no_path_indirection(path, "model artifact")
    if not path.is_file() or path.stat().st_size != contract["size_bytes"]:
        return True
    try:
        return sha256_file(path) != contract["sha256"]
    except OSError:
        return True


def ensure_capacity(backup_root: Path, records: list[dict[str, Any]]) -> None:
    missing_bytes = 0
    for record in records:
        target = backup_root / record["id"]
        assert_vault_path(target, backup_root, "model directory", require_exists=False)
        if os.path.lexists(target):
            ensure_vault_directory(target, backup_root, "model directory")
        for contract in artifact_contracts(record):
            if artifact_needs_replacement(
                target / contract["filename"],
                contract,
                backup_root=backup_root,
            ):
                missing_bytes += contract["size_bytes"]
    free_bytes = shutil.disk_usage(backup_root).free
    if free_bytes < missing_bytes + RESERVE_BYTES:
        raise BackupError(
            f"Insufficient backup capacity: free={free_bytes}, "
            f"required_with_reserve={missing_bytes + RESERVE_BYTES}"
        )


def manifest_snapshot_relative_path(manifest_sha256: str) -> Path:
    if re.fullmatch(r"[0-9a-f]{64}", manifest_sha256) is None:
        raise BackupError("Invalid model manifest SHA-256")
    return Path("config") / f"models.{manifest_sha256}.json"


def persist_manifest_snapshot(
    backup_root: Path,
    manifest_path: Path,
    manifest_sha256: str,
) -> Path:
    """Persist the active manifest immutably without replacing an older snapshot."""

    payload = manifest_path.read_bytes()
    if hashlib.sha256(payload).hexdigest() != manifest_sha256:
        raise BackupError("Model manifest changed during backup verification")
    snapshot_dir = backup_root / "config"
    ensure_vault_directory(snapshot_dir, backup_root, "manifest snapshot directory")
    relative = manifest_snapshot_relative_path(manifest_sha256)
    versioned = backup_root / relative
    assert_vault_path(
        versioned,
        backup_root,
        "versioned model manifest snapshot",
        require_exists=False,
    )
    write_once_bytes(versioned, payload, "model manifest snapshot")
    assert_vault_regular_file(
        versioned,
        backup_root,
        "versioned model manifest snapshot",
    )
    if sha256_file(versioned) != manifest_sha256:
        raise BackupError("Versioned model manifest snapshot failed SHA-256 verification")

    # Keep the original compatibility snapshot immutable.  New archive markers
    # bind the content-addressed file above, so a later pin cannot destroy the
    # manifest bytes needed to interpret an older model generation.
    compatibility_snapshot = snapshot_dir / "models.json"
    assert_vault_path(
        compatibility_snapshot,
        backup_root,
        "compatibility model manifest snapshot",
        require_exists=False,
    )
    if not os.path.lexists(compatibility_snapshot):
        write_once_bytes(
            compatibility_snapshot,
            payload,
            "compatibility model manifest snapshot",
        )
    else:
        assert_vault_regular_file(
            compatibility_snapshot,
            backup_root,
            "compatibility model manifest snapshot",
        )
    return relative


def verify_manifest_snapshot(
    backup_root: Path,
    manifest_sha256: str,
) -> Path:
    relative = manifest_snapshot_relative_path(manifest_sha256)
    snapshot = backup_root / relative
    if not os.path.lexists(snapshot):
        raise BackupError(f"Versioned model manifest snapshot is missing: {snapshot}")
    safe_snapshot = assert_vault_regular_file(
        snapshot,
        backup_root,
        "versioned model manifest snapshot",
    )
    if sha256_file(safe_snapshot) != manifest_sha256:
        raise BackupError("Versioned model manifest snapshot failed SHA-256 verification")
    return relative


def completion_for_archive(
    backup_root: Path,
    record: dict[str, Any],
    manifest_sha256: str,
) -> dict[str, Any] | None:
    model_dir = backup_root / record["id"]
    assert_vault_path(model_dir, backup_root, "model directory", require_exists=False)
    if not os.path.lexists(model_dir):
        return None
    ensure_vault_directory(model_dir, backup_root, "model directory")
    path = model_dir / ".complete.json"
    assert_vault_path(path, backup_root, "completion marker", require_exists=False)
    if not os.path.lexists(path):
        return None
    assert_vault_regular_file(path, backup_root, "completion marker")
    try:
        marker = load_json(path, "model completion marker")
        if (
            marker.get("schema_version") != MODEL_COMPLETION_SCHEMA_VERSION
            or marker.get("complete") is not True
            or marker.get("model_id") != record["id"]
            or marker.get("repo_id") != record["repo_id"]
            or marker.get("revision") != record["revision"]
            or marker.get("manifest_sha256") != manifest_sha256
        ):
            return None
        acquisition_relative = marker.get("acquisition_relative_path")
        verification_relative = marker.get("verification_relative_path")
        if (
            not isinstance(acquisition_relative, str)
            or not isinstance(verification_relative, str)
            or acquisition_relative != ACQUISITION_RELATIVE_PATH.as_posix()
            or verification_relative != VERIFICATION_FILENAME
        ):
            return None
        acquisition_path = model_dir / acquisition_relative
        verification_path = model_dir / verification_relative
        if not os.path.lexists(acquisition_path) or not os.path.lexists(verification_path):
            return None
        assert_vault_regular_file(
            acquisition_path,
            backup_root,
            "immutable acquisition metadata",
        )
        assert_vault_regular_file(
            verification_path,
            backup_root,
            "verification metadata",
        )
        acquisition_sha256 = sha256_file(acquisition_path)
        verification_sha256 = sha256_file(verification_path)
        if acquisition_sha256 != marker.get("acquisition_sha256"):
            return None
        if verification_sha256 != marker.get("verification_sha256"):
            return None

        acquisition = load_json(acquisition_path, "immutable acquisition metadata")
        validate_acquisition(acquisition, record, acquisition_path)
        verify_provenance_files(
            model_dir,
            acquisition,
            backup_root=backup_root,
        )
        artifacts = verify_artifacts(
            model_dir,
            artifact_contracts(record),
            backup_root=backup_root,
        )
        if marker.get("artifacts") != artifacts:
            return None

        verification = load_json(verification_path, "verification record")
        if (
            verification.get("schema_version") != 1
            or verification.get("model_id") != record["id"]
            or verification.get("repo_id") != record["repo_id"]
            or verification.get("revision") != record["revision"]
            or verification.get("manifest_sha256") != manifest_sha256
            or verification.get("acquisition_relative_path")
            != ACQUISITION_RELATIVE_PATH.as_posix()
            or verification.get("acquisition_sha256") != acquisition_sha256
            or verification.get("artifacts") != artifacts
        ):
            return None
    except UnsafePathError:
        raise
    except (BackupError, OSError):
        return None
    return marker


def build_archive_manifest(
    backup_root: Path,
    manifest: dict[str, Any],
    manifest_sha256: str,
    requested_models: list[str],
) -> dict[str, Any]:
    snapshot_relative_path = verify_manifest_snapshot(backup_root, manifest_sha256)
    markers: dict[str, dict[str, Any]] = {}
    for model_id in SUPPORTED_MODEL_IDS:
        record = model_record(manifest, model_id)
        marker = completion_for_archive(backup_root, record, manifest_sha256)
        if marker is not None:
            markers[model_id] = marker
    complete_for_requested = all(model_id in markers for model_id in requested_models)
    required_models_complete = all(model_id in markers for model_id in REQUIRED_MODEL_IDS)
    all_supported_models_complete = all(
        model_id in markers for model_id in SUPPORTED_MODEL_IDS
    )
    return {
        "schema_version": ARCHIVE_MANIFEST_SCHEMA_VERSION,
        "complete_for_requested_models": complete_for_requested,
        "required_models_complete": required_models_complete,
        "all_supported_models_complete": all_supported_models_complete,
        "supported_models": list(SUPPORTED_MODEL_IDS),
        "default_models": list(DEFAULT_MODEL_IDS),
        "required_models": list(REQUIRED_MODEL_IDS),
        "optional_models": list(OPTIONAL_MODEL_IDS),
        "requested_models": requested_models,
        "manifest_sha256": manifest_sha256,
        "manifest_snapshot_relative_path": snapshot_relative_path.as_posix(),
        "manifest_snapshot_sha256": manifest_sha256,
        "backup_root": str(backup_root),
        "updated_at_utc": utc_now(),
        "models": [markers[item] for item in SUPPORTED_MODEL_IDS if item in markers],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--backup-root", type=Path, required=True)
    parser.add_argument(
        "--model",
        action="append",
        choices=SUPPORTED_MODEL_IDS,
        dest="models",
    )
    parser.add_argument("--verify-only", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    manifest_path = args.manifest.resolve(strict=True)
    project_root = manifest_path.parent.parent
    requested_backup_root = _absolute_path(args.backup_root)
    if path_is_same_or_descendant(requested_backup_root, project_root):
        raise BackupError("Backup vault must be outside the project root")
    backup_root = prepare_backup_root(requested_backup_root)
    if path_is_same_or_descendant(backup_root, project_root):
        raise BackupError("Backup vault must be outside the project root")
    hf_home_value = os.environ.get("HF_HOME")
    if not args.verify_only:
        if not hf_home_value:
            raise BackupError("Download mode requires HF_HOME inside the backup root")
        hf_home = Path(hf_home_value)
        assert_vault_path(
            hf_home,
            backup_root,
            "Hugging Face cache root",
            require_exists=False,
        )
        if os.path.lexists(hf_home):
            ensure_vault_directory(hf_home, backup_root, "Hugging Face cache root")
            assert_no_path_indirection_tree(hf_home, "Hugging Face cache root")

    atomic_replace_smoke(backup_root)
    manifest, manifest_sha256 = load_manifest(manifest_path)
    model_ids = args.models or list(DEFAULT_MODEL_IDS)
    records = [model_record(manifest, item) for item in model_ids]
    if not args.verify_only:
        ensure_capacity(backup_root, records)

    for record in records:
        verify_or_download_model(
            backup_root,
            record,
            manifest_sha256,
            args.verify_only,
        )
        # Commit the content-addressed manifest after every successfully
        # migrated model. If a later requested model fails, the already
        # refreshed marker remains usable with this exact snapshot.
        persist_manifest_snapshot(backup_root, manifest_path, manifest_sha256)
    archive = build_archive_manifest(
        backup_root,
        manifest,
        manifest_sha256,
        model_ids,
    )
    if not archive["complete_for_requested_models"]:
        raise BackupError("Requested models did not produce complete archive markers")
    archive_path = backup_root / "archive-manifest.json"
    assert_vault_path(
        archive_path,
        backup_root,
        "archive manifest",
        require_exists=False,
    )
    atomic_json(archive_path, archive)
    assert_vault_regular_file(archive_path, backup_root, "archive manifest")
    print(json.dumps(archive, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BackupError as exc:
        print(f"model backup error: {exc}", file=sys.stderr)
        raise SystemExit(1)

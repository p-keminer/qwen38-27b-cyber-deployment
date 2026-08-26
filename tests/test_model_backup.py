import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "model_backup.py"
SPEC = importlib.util.spec_from_file_location("model_backup", SCRIPT)
assert SPEC and SPEC.loader
model_backup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(model_backup)


class ModelBackupTests(unittest.TestCase):
    def test_atomic_bytes_replaces_content_without_metadata_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "config" / "models.json"
            target.parent.mkdir(parents=True)
            target.write_bytes(b"old")
            with mock.patch.object(
                model_backup.shutil,
                "copy2",
                side_effect=AssertionError("metadata copy must not run"),
            ):
                model_backup.atomic_bytes(target, b"new")
            self.assertEqual(target.read_bytes(), b"new")
            self.assertEqual(list(target.parent.glob("*.tmp")), [])

    def artifact(self, role: str, filename: str, payload: bytes):
        return {
            "role": role,
            "filename": filename,
            "size_bytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }

    def record(
        self,
        model_id: str,
        model_payload: bytes,
        projector_payload: bytes,
    ):
        return {
            "id": model_id,
            "repo_id": f"owner/{model_id}",
            "revision": ("a" if model_id == "uncensored-q6" else "b") * 40,
            "filename": f"{model_id}.gguf",
            "expected_size_bytes": len(model_payload),
            "sha256": hashlib.sha256(model_payload).hexdigest(),
            "vision_projector": {
                "filename": f"{model_id}-projector.gguf",
                "expected_size_bytes": len(projector_payload),
                "sha256": hashlib.sha256(projector_payload).hexdigest(),
            },
        }

    def supported_manifest(self, *records: dict) -> dict:
        records_by_id = {record["id"]: record for record in records}
        for model_id in model_backup.SUPPORTED_MODEL_IDS:
            if model_id in records_by_id:
                continue
            model_payload = f"{model_id}-model".encode()
            projector_payload = f"{model_id}-projector".encode()
            records_by_id[model_id] = self.record(
                model_id,
                model_payload,
                projector_payload,
            )
        return {
            "schema_version": 1,
            "models": [
                records_by_id[model_id]
                for model_id in model_backup.SUPPORTED_MODEL_IDS
            ],
        }

    def materialize_model(
        self,
        backup_root: Path,
        record: dict,
        model_payload: bytes,
        projector_payload: bytes,
        *,
        with_acquisition: bool = True,
        provenance_files: list[dict] | None = None,
    ) -> Path:
        target = backup_root / record["id"]
        target.mkdir(parents=True, exist_ok=True)
        (target / record["filename"]).write_bytes(model_payload)
        (target / record["vision_projector"]["filename"]).write_bytes(
            projector_payload
        )
        if with_acquisition:
            acquisition = {
                "schema_version": 1,
                "model_id": record["id"],
                "repo_id": record["repo_id"],
                "requested_revision": record["revision"],
                "resolved_revision": record["revision"],
                "artifact_source": "fixture",
                "captured_at_utc": "2026-08-26T00:00:00Z",
                "artifacts": model_backup.artifact_contracts(record),
                "provenance_files": provenance_files or [],
            }
            model_backup.write_once_json(
                target / model_backup.ACQUISITION_RELATIVE_PATH,
                acquisition,
            )
        return target

    def test_verify_artifact_accepts_exact_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "model.gguf"
            payload = b"exact pinned gguf"
            path.write_bytes(payload)
            result = model_backup.verify_artifact(
                path, self.artifact("model", path.name, payload)
            )
            self.assertEqual(result["size_bytes"], len(payload))

    def test_verify_artifact_rejects_same_size_corruption(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "model.gguf"
            expected = b"expected"
            path.write_bytes(b"corrupt!")
            with self.assertRaisesRegex(model_backup.BackupError, "SHA-256 mismatch"):
                model_backup.verify_artifact(
                    path, self.artifact("model", path.name, expected)
                )

    def test_atomic_json_never_leaves_temporary_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / ".complete.json"
            model_backup.atomic_json(path, {"complete": True})
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), {"complete": True})
            self.assertEqual(list(path.parent.glob(".*.tmp")), [])

    def test_atomic_replace_smoke_replaces_reopens_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model_backup.atomic_replace_smoke(root)
            self.assertEqual(list(root.glob(".model-backup-atomic-smoke.*")), [])

    def test_acquisition_writer_never_replaces_existing_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "provenance" / "acquisition.json"
            model_backup.write_once_json(path, {"generation": 1})
            original = path.read_bytes()
            with self.assertRaisesRegex(model_backup.BackupError, "Immutable metadata"):
                model_backup.write_once_json(path, {"generation": 2})
            self.assertEqual(path.read_bytes(), original)

    def test_verify_only_is_stdlib_only_and_preserves_acquisition(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model_payload = b"verified local model"
            projector_payload = b"verified local projector"
            record = self.record(
                "uncensored-q6", model_payload, projector_payload
            )
            target = self.materialize_model(
                root,
                record,
                model_payload,
                projector_payload,
            )
            acquisition = target / model_backup.ACQUISITION_RELATIVE_PATH
            acquisition_before = acquisition.read_bytes()
            with mock.patch.object(
                model_backup,
                "download_record",
                side_effect=AssertionError("verify-only attempted Hub access"),
            ), mock.patch.object(
                model_backup.importlib.metadata,
                "version",
                side_effect=AssertionError("verify-only resolved a package"),
            ):
                marker = model_backup.verify_or_download_model(
                    root,
                    record,
                    "f" * 64,
                    verify_only=True,
                )
            self.assertEqual(acquisition.read_bytes(), acquisition_before)
            self.assertEqual(marker["schema_version"], 3)
            self.assertTrue((target / model_backup.VERIFICATION_FILENAME).is_file())
            self.assertNotIn("huggingface_hub_version", marker)

    def test_existing_weights_backfill_missing_acquisition_in_normal_mode(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model_payload = b"preexisting model"
            projector_payload = b"preexisting projector"
            record = self.record(
                "uncensored-q6", model_payload, projector_payload
            )
            target = self.materialize_model(
                root,
                record,
                model_payload,
                projector_payload,
                with_acquisition=False,
            )
            refreshed = {
                "schema_version": 1,
                "model_id": record["id"],
                "repo_id": record["repo_id"],
                "requested_revision": record["revision"],
                "resolved_revision": record["revision"],
                "artifact_source": "preexisting_verified_local",
                "captured_at_utc": "2026-08-26T00:00:00Z",
                "artifacts": model_backup.artifact_contracts(record),
                "provenance_files": [],
            }
            with mock.patch.object(
                model_backup, "download_record", return_value=refreshed
            ) as fetch:
                model_backup.verify_or_download_model(
                    root,
                    record,
                    "e" * 64,
                    verify_only=False,
                )
            self.assertFalse(fetch.call_args.kwargs["download_artifacts"])
            acquisition = target / model_backup.ACQUISITION_RELATIVE_PATH
            self.assertEqual(
                json.loads(acquisition.read_text(encoding="utf-8")), refreshed
            )
            acquisition_before = acquisition.read_bytes()
            with mock.patch.object(
                model_backup,
                "download_record",
                side_effect=AssertionError("verification changed acquisition"),
            ):
                model_backup.verify_or_download_model(
                    root,
                    record,
                    "e" * 64,
                    verify_only=True,
                )
            self.assertEqual(acquisition.read_bytes(), acquisition_before)

    def test_normal_mode_restores_missing_small_provenance_without_replacing_acquisition(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model_payload = b"model"
            projector_payload = b"projector"
            provenance_payload = b"pinned upstream readme"
            provenance_contract = {
                "filename": "README.md",
                "relative_path": "provenance/README.md",
                "size_bytes": len(provenance_payload),
                "sha256": hashlib.sha256(provenance_payload).hexdigest(),
            }
            record = self.record(
                "uncensored-q6", model_payload, projector_payload
            )
            target = self.materialize_model(
                root,
                record,
                model_payload,
                projector_payload,
                provenance_files=[provenance_contract],
            )
            acquisition_path = target / model_backup.ACQUISITION_RELATIVE_PATH
            acquisition = json.loads(acquisition_path.read_text(encoding="utf-8"))
            acquisition_before = acquisition_path.read_bytes()

            def restore(*_args, **kwargs):
                self.assertFalse(kwargs["download_artifacts"])
                provenance_path = target / "provenance" / "README.md"
                provenance_path.write_bytes(provenance_payload)
                return acquisition

            with mock.patch.object(
                model_backup, "download_record", side_effect=restore
            ) as fetch:
                model_backup.verify_or_download_model(
                    root,
                    record,
                    "d" * 64,
                    verify_only=False,
                )
            fetch.assert_called_once()
            self.assertEqual(acquisition_path.read_bytes(), acquisition_before)

    def test_provenance_contract_requires_canonical_typed_unique_entries(self):
        digest = hashlib.sha256(b"provenance").hexdigest()
        valid = {
            "filename": "README.md",
            "relative_path": "provenance/README.md",
            "size_bytes": 10,
            "sha256": digest,
        }
        invalid_contracts = [
            [{key: value for key, value in valid.items() if key != "filename"}],
            [dict(valid, relative_path="README.md")],
            [dict(valid, size_bytes=True)],
            [dict(valid, size_bytes=-1)],
            [dict(valid, size_bytes=2**63)],
            [dict(valid, sha256=digest.upper())],
            [valid, dict(valid, filename="readme.MD", relative_path="provenance/readme.MD")],
        ]
        for contracts in invalid_contracts:
            with self.subTest(contracts=contracts):
                with self.assertRaises(model_backup.BackupError):
                    model_backup.validate_provenance_contracts(contracts)

    def test_verify_only_rejects_bad_provenance_before_writing_markers(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model_payload = b"model"
            projector_payload = b"projector"
            record = self.record("uncensored-q6", model_payload, projector_payload)
            invalid_contract = {
                "relative_path": "provenance/README.md",
                "size_bytes": 0,
                "sha256": hashlib.sha256(b"").hexdigest(),
            }
            target = self.materialize_model(
                root,
                record,
                model_payload,
                projector_payload,
                provenance_files=[invalid_contract],
            )
            (target / "provenance" / "README.md").write_bytes(b"")
            with self.assertRaisesRegex(
                model_backup.BackupError,
                "Invalid immutable provenance",
            ):
                model_backup.verify_or_download_model(
                    root,
                    record,
                    "f" * 64,
                    verify_only=True,
                )
            self.assertFalse((target / "verification.json").exists())
            self.assertFalse((target / ".complete.json").exists())

    def test_model_directory_symlink_escape_is_rejected_without_markers(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            vault = base / "vault"
            external = base / "external"
            vault.mkdir()
            model_payload = b"model"
            projector_payload = b"projector"
            record = self.record("uncensored-q6", model_payload, projector_payload)
            external_target = self.materialize_model(
                external,
                record,
                model_payload,
                projector_payload,
            )
            try:
                os.symlink(
                    external_target,
                    vault / record["id"],
                    target_is_directory=True,
                )
            except OSError as exc:
                if os.name != "nt":
                    self.skipTest(f"directory symlinks are unavailable: {exc}")
                powershell = shutil.which("powershell.exe") or shutil.which("powershell")
                if powershell is None:
                    self.skipTest(f"directory links are unavailable: {exc}")
                command = (
                    "New-Item -ItemType Junction -Path "
                    f"'{str(vault / record['id']).replace("'", "''")}' -Target "
                    f"'{str(external_target).replace("'", "''")}' | Out-Null"
                )
                created = subprocess.run(
                    [powershell, "-NoProfile", "-Command", command],
                    cwd=ROOT,
                    capture_output=True,
                    text=True,
                    timeout=30,
                    check=False,
                )
                self.assertEqual(created.returncode, 0, created.stderr)
            with self.assertRaises(model_backup.UnsafePathError):
                model_backup.verify_or_download_model(
                    vault,
                    record,
                    "e" * 64,
                    verify_only=True,
                )
            self.assertFalse((external_target / "verification.json").exists())
            self.assertFalse((external_target / ".complete.json").exists())

    def test_same_size_corruption_counts_full_replacement_capacity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            expected_model = b"expected"
            corrupt_model = b"corrupt!"
            projector = b"projector"
            record = self.record("uncensored-q6", expected_model, projector)
            self.materialize_model(
                root,
                record,
                corrupt_model,
                projector,
                with_acquisition=False,
            )
            free = model_backup.RESERVE_BYTES + len(expected_model) - 1
            with mock.patch.object(
                model_backup.shutil,
                "disk_usage",
                return_value=SimpleNamespace(free=free),
            ):
                with self.assertRaisesRegex(
                    model_backup.BackupError, "Insufficient backup capacity"
                ):
                    model_backup.ensure_capacity(root, [record])

    def test_verify_only_skips_download_capacity_reserve(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            project = base / "project"
            config = project / "config"
            vault = base / "vault"
            config.mkdir(parents=True)
            q6_model, q6_projector = b"q6", b"q6-projector"
            q4_model, q4_projector = b"q4", b"q4-projector"
            q6 = self.record("uncensored-q6", q6_model, q6_projector)
            q4 = self.record("whitehat-q4", q4_model, q4_projector)
            manifest_path = config / "models.json"
            manifest_path.write_text(
                json.dumps(self.supported_manifest(q6, q4)),
                encoding="utf-8",
            )
            self.materialize_model(vault, q6, q6_model, q6_projector)
            argv = [
                str(SCRIPT),
                "--manifest",
                str(manifest_path),
                "--backup-root",
                str(vault),
                "--model",
                "uncensored-q6",
                "--verify-only",
            ]
            with mock.patch.object(model_backup.sys, "argv", argv), mock.patch.object(
                model_backup,
                "ensure_capacity",
                side_effect=AssertionError("verify-only applied download reserve"),
            ), mock.patch.object(
                model_backup.shutil,
                "disk_usage",
                return_value=SimpleNamespace(free=0),
            ), mock.patch.object(
                model_backup,
                "download_record",
                side_effect=AssertionError("verify-only attempted Hub access"),
            ), mock.patch.dict(
                model_backup.os.environ,
                {"HF_HOME": str(project / "ambient-hf-cache")},
                clear=False,
            ), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(model_backup.main(), 0)

    def test_failed_pin_change_preserves_last_good_manifest_snapshot_and_markers(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            project = base / "project"
            config = project / "config"
            vault = base / "vault"
            config.mkdir(parents=True)
            q6_model, q6_projector = b"q6", b"q6-projector"
            q4_model, q4_projector = b"q4", b"q4-projector"
            q6 = self.record("uncensored-q6", q6_model, q6_projector)
            q4 = self.record("whitehat-q4", q4_model, q4_projector)
            manifest_path = config / "models.json"
            manifest_a = self.supported_manifest(q6, q4)
            payload_a = json.dumps(manifest_a, sort_keys=True).encode("utf-8")
            manifest_path.write_bytes(payload_a)
            sha_a = hashlib.sha256(payload_a).hexdigest()
            target = self.materialize_model(vault, q6, q6_model, q6_projector)
            argv = [
                str(SCRIPT),
                "--manifest",
                str(manifest_path),
                "--backup-root",
                str(vault),
                "--model",
                "uncensored-q6",
                "--verify-only",
            ]
            with mock.patch.object(model_backup.sys, "argv", argv), mock.patch.dict(
                os.environ, {"HF_HOME": ""}
            ), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(model_backup.main(), 0)
            compatibility_snapshot = vault / "config" / "models.json"
            versioned_a = vault / model_backup.manifest_snapshot_relative_path(sha_a)
            marker_before = (target / ".complete.json").read_bytes()
            archive_before = (vault / "archive-manifest.json").read_bytes()

            manifest_b = json.loads(json.dumps(manifest_a))
            manifest_b["models"][0]["revision"] = "c" * 40
            payload_b = json.dumps(manifest_b, sort_keys=True).encode("utf-8")
            sha_b = hashlib.sha256(payload_b).hexdigest()
            manifest_path.write_bytes(payload_b)
            with mock.patch.object(model_backup.sys, "argv", argv), mock.patch.dict(
                os.environ, {"HF_HOME": ""}
            ), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(
                    model_backup.BackupError,
                    "does not match the model pin",
                ):
                    model_backup.main()

            self.assertEqual(compatibility_snapshot.read_bytes(), payload_a)
            self.assertEqual(versioned_a.read_bytes(), payload_a)
            self.assertFalse(
                (vault / model_backup.manifest_snapshot_relative_path(sha_b)).exists()
            )
            self.assertEqual((target / ".complete.json").read_bytes(), marker_before)
            self.assertEqual((vault / "archive-manifest.json").read_bytes(), archive_before)

    def test_archive_manifest_merges_model_markers_and_scopes_completeness(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payloads = {
                model_id: (
                    f"{model_id}-model".encode(),
                    f"{model_id}-projector".encode(),
                )
                for model_id in model_backup.SUPPORTED_MODEL_IDS
            }
            records = {
                model_id: self.record(model_id, *payloads[model_id])
                for model_id in model_backup.SUPPORTED_MODEL_IDS
            }
            manifest = self.supported_manifest(*records.values())
            manifest_payload = json.dumps(manifest, sort_keys=True).encode("utf-8")
            manifest_sha = hashlib.sha256(manifest_payload).hexdigest()
            snapshot = root / model_backup.manifest_snapshot_relative_path(manifest_sha)
            model_backup.write_once_bytes(
                snapshot,
                manifest_payload,
                "fixture model manifest snapshot",
            )
            q6 = records["uncensored-q6"]
            q4 = records["uncensored-q4"]
            whitehat = records["whitehat-q4"]
            q8 = records["uncensored-q8"]
            self.materialize_model(root, q6, *payloads[q6["id"]])
            model_backup.verify_or_download_model(
                root, q6, manifest_sha, verify_only=True
            )
            partial = model_backup.build_archive_manifest(
                root, manifest, manifest_sha, ["uncensored-q6"]
            )
            self.assertEqual(partial["schema_version"], 3)
            self.assertTrue(partial["complete_for_requested_models"])
            self.assertFalse(partial["required_models_complete"])
            self.assertFalse(partial["all_supported_models_complete"])
            self.assertNotIn("complete", partial)
            self.assertNotIn("globally_complete", partial)
            self.assertEqual(
                partial["default_models"], list(model_backup.DEFAULT_MODEL_IDS)
            )
            self.assertEqual(
                partial["required_models"], list(model_backup.REQUIRED_MODEL_IDS)
            )
            self.assertEqual(
                partial["optional_models"], list(model_backup.OPTIONAL_MODEL_IDS)
            )
            self.assertEqual(len(partial["models"]), 1)

            self.materialize_model(root, q4, *payloads[q4["id"]])
            model_backup.verify_or_download_model(
                root, q4, manifest_sha, verify_only=True
            )
            required_complete = model_backup.build_archive_manifest(
                root, manifest, manifest_sha, ["uncensored-q4"]
            )
            self.assertTrue(required_complete["complete_for_requested_models"])
            self.assertTrue(required_complete["required_models_complete"])
            self.assertFalse(required_complete["all_supported_models_complete"])
            self.assertEqual(len(required_complete["models"]), 2)

            for optional in (whitehat, q8):
                self.materialize_model(
                    root,
                    optional,
                    *payloads[optional["id"]],
                )
                model_backup.verify_or_download_model(
                    root,
                    optional,
                    manifest_sha,
                    verify_only=True,
                )
            all_complete = model_backup.build_archive_manifest(
                root, manifest, manifest_sha, ["whitehat-q4", "uncensored-q8"]
            )
            self.assertTrue(all_complete["complete_for_requested_models"])
            self.assertTrue(all_complete["required_models_complete"])
            self.assertTrue(all_complete["all_supported_models_complete"])
            self.assertEqual(len(all_complete["models"]), 4)

            (root / q8["id"] / q8["filename"]).write_bytes(b"broken-optional")
            after_optional_corruption = model_backup.build_archive_manifest(
                root, manifest, manifest_sha, ["uncensored-q6"]
            )
            self.assertTrue(after_optional_corruption["complete_for_requested_models"])
            self.assertTrue(after_optional_corruption["required_models_complete"])
            self.assertFalse(
                after_optional_corruption["all_supported_models_complete"]
            )
            self.assertEqual(
                [item["model_id"] for item in after_optional_corruption["models"]],
                ["uncensored-q6", "uncensored-q4", "whitehat-q4"],
            )

            (root / q4["id"] / q4["filename"]).write_bytes(b"broken-required")
            after_required_corruption = model_backup.build_archive_manifest(
                root, manifest, manifest_sha, ["uncensored-q6"]
            )
            self.assertTrue(after_required_corruption["complete_for_requested_models"])
            self.assertFalse(after_required_corruption["required_models_complete"])
            self.assertFalse(
                after_required_corruption["all_supported_models_complete"]
            )

    def test_v2_usb_markers_migrate_in_safe_required_then_optional_sequence(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            project = base / "project"
            config = project / "config"
            vault = base / "vault"
            config.mkdir(parents=True)
            payloads = {
                model_id: (
                    f"{model_id}-migration-model".encode(),
                    f"{model_id}-migration-projector".encode(),
                )
                for model_id in model_backup.SUPPORTED_MODEL_IDS
            }
            records = {
                model_id: self.record(model_id, *payloads[model_id])
                for model_id in model_backup.SUPPORTED_MODEL_IDS
            }
            old_manifest = self.supported_manifest(*records.values())
            old_manifest["generation"] = "v2-usb"
            old_payload = json.dumps(old_manifest, sort_keys=True).encode("utf-8")
            old_sha = hashlib.sha256(old_payload).hexdigest()
            manifest_path = config / "models.json"
            manifest_path.write_bytes(old_payload)

            for model_id in ("uncensored-q6", "whitehat-q4"):
                record = records[model_id]
                self.materialize_model(vault, record, *payloads[model_id])
                model_backup.verify_or_download_model(
                    vault,
                    record,
                    old_sha,
                    verify_only=True,
                )
                marker_path = vault / model_id / ".complete.json"
                marker = json.loads(marker_path.read_text(encoding="utf-8"))
                marker["schema_version"] = 2
                marker_path.write_text(json.dumps(marker), encoding="utf-8")

            model_backup.persist_manifest_snapshot(vault, manifest_path, old_sha)
            old_archive = {
                "schema_version": 2,
                "complete": True,
                "globally_complete": True,
                "manifest_sha256": old_sha,
            }
            archive_path = vault / "archive-manifest.json"
            archive_path.write_text(json.dumps(old_archive), encoding="utf-8")
            self.assertIsNone(
                model_backup.completion_for_archive(
                    vault,
                    records["uncensored-q6"],
                    old_sha,
                )
            )

            new_manifest = json.loads(json.dumps(old_manifest))
            new_manifest["generation"] = "v3-required-first"
            new_payload = json.dumps(new_manifest, sort_keys=True).encode("utf-8")
            new_sha = hashlib.sha256(new_payload).hexdigest()
            manifest_path.write_bytes(new_payload)

            def invoke(*model_ids: str) -> int:
                argv = [
                    str(SCRIPT),
                    "--manifest",
                    str(manifest_path),
                    "--backup-root",
                    str(vault),
                ]
                for model_id in model_ids:
                    argv.extend(("--model", model_id))
                argv.append("--verify-only")
                with mock.patch.object(model_backup.sys, "argv", argv), mock.patch.dict(
                    os.environ,
                    {"HF_HOME": ""},
                ), contextlib.redirect_stdout(io.StringIO()):
                    return model_backup.main()

            # Rebind the tested Q6 first. This creates its v3 marker and the new
            # content-addressed snapshot before any new Q4 bytes are required.
            self.assertEqual(invoke("uncensored-q6"), 0)
            q6_marker_path = vault / "uncensored-q6" / ".complete.json"
            q6_marker = json.loads(q6_marker_path.read_text(encoding="utf-8"))
            self.assertEqual(q6_marker["schema_version"], 3)
            self.assertEqual(q6_marker["manifest_sha256"], new_sha)
            self.assertTrue(
                (vault / model_backup.manifest_snapshot_relative_path(new_sha)).is_file()
            )
            self.assertEqual((vault / "config" / "models.json").read_bytes(), old_payload)
            q6_marker_after_rebind = q6_marker_path.read_bytes()
            archive_after_q6 = archive_path.read_bytes()
            partial = json.loads(archive_after_q6)
            self.assertEqual(partial["schema_version"], 3)
            self.assertTrue(partial["complete_for_requested_models"])
            self.assertFalse(partial["required_models_complete"])
            self.assertFalse(partial["all_supported_models_complete"])

            # A missing new Q4 must not roll back or invalidate the already
            # migrated Q6 generation.
            with self.assertRaisesRegex(
                model_backup.BackupError,
                "Missing backup artifact",
            ):
                invoke("uncensored-q4")
            self.assertEqual(q6_marker_path.read_bytes(), q6_marker_after_rebind)
            self.assertEqual(archive_path.read_bytes(), archive_after_q6)

            q4 = records["uncensored-q4"]
            self.materialize_model(vault, q4, *payloads[q4["id"]])
            self.assertEqual(invoke("uncensored-q4"), 0)
            required_complete = json.loads(archive_path.read_text(encoding="utf-8"))
            self.assertTrue(required_complete["required_models_complete"])
            self.assertFalse(required_complete["all_supported_models_complete"])
            self.assertEqual(
                [item["model_id"] for item in required_complete["models"]],
                ["uncensored-q6", "uncensored-q4"],
            )

            # With no --model arguments the Python entry point must select only
            # the two default/required Uncensored profiles.
            self.assertEqual(invoke(), 0)
            default_run = json.loads(archive_path.read_text(encoding="utf-8"))
            self.assertEqual(
                default_run["requested_models"],
                ["uncensored-q6", "uncensored-q4"],
            )
            self.assertTrue(default_run["required_models_complete"])
            self.assertFalse(default_run["all_supported_models_complete"])

            # The old Whitehat v2 marker remains excluded until the optional
            # profile itself is explicitly reverified under the new manifest.
            self.assertEqual(invoke("whitehat-q4"), 0)
            optional_rebound = json.loads(archive_path.read_text(encoding="utf-8"))
            self.assertTrue(optional_rebound["required_models_complete"])
            self.assertFalse(optional_rebound["all_supported_models_complete"])
            self.assertEqual(
                [item["model_id"] for item in optional_rebound["models"]],
                ["uncensored-q6", "uncensored-q4", "whitehat-q4"],
            )
            whitehat_marker = json.loads(
                (vault / "whitehat-q4" / ".complete.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(whitehat_marker["schema_version"], 3)
            self.assertEqual(whitehat_marker["manifest_sha256"], new_sha)

    def test_manifest_rejects_artifact_path_escape(self):
        record = self.record("uncensored-q6", b"model", b"projector")
        record["filename"] = "../outside.gguf"
        manifest = {"schema_version": 1, "models": [record]}
        with self.assertRaisesRegex(model_backup.BackupError, "Unsafe artifact filename"):
            model_backup.model_record(manifest, "uncensored-q6")

    @unittest.skipUnless(os.name == "nt", "Windows path semantics required")
    def test_python_project_containment_is_case_insensitive_on_windows(self):
        different_case = Path(str(ROOT).swapcase())
        self.assertTrue(model_backup.path_is_same_or_descendant(different_case, ROOT))
        resolved_script = model_backup.assert_vault_path(
            Path(str(SCRIPT).swapcase()),
            ROOT,
            "case-insensitive fixture",
            require_exists=True,
        )
        self.assertTrue(os.path.samefile(resolved_script, SCRIPT))
        with tempfile.TemporaryDirectory() as temporary:
            prepared = model_backup.prepare_backup_root(Path(temporary).resolve())
            prepared_with_other_case = model_backup.prepare_backup_root(
                Path(str(prepared).swapcase())
            )
            self.assertTrue(os.path.samefile(prepared, prepared_with_other_case))

    def test_manifest_snapshots_are_write_once_and_preserve_compatibility_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            project_manifest = base / "project" / "config" / "models.json"
            project_manifest.parent.mkdir(parents=True)
            payload = b'{"schema_version":1,"models":[]}\n'
            project_manifest.write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            vault = base / "vault"
            snapshot_dir = vault / "config"
            snapshot_dir.mkdir(parents=True)
            compatibility = snapshot_dir / "models.json"
            compatibility.write_bytes(b"first successful snapshot")
            model_backup.persist_manifest_snapshot(vault, project_manifest, digest)
            self.assertEqual(compatibility.read_bytes(), b"first successful snapshot")

            versioned = vault / model_backup.manifest_snapshot_relative_path(digest)
            versioned.write_bytes(b"foreign bytes")
            with self.assertRaisesRegex(
                model_backup.BackupError,
                "Immutable model manifest snapshot has different bytes",
            ):
                model_backup.persist_manifest_snapshot(vault, project_manifest, digest)
            self.assertEqual(versioned.read_bytes(), b"foreign bytes")

    def test_manifest_contains_exact_backup_models(self):
        manifest, digest = model_backup.load_manifest(ROOT / "config" / "models.json")
        self.assertEqual(
            digest,
            "5a48ce041aee4310103d26ceb540442fe6443c1090bf235e2a58dae4b01bdcdf",
        )
        q6 = model_backup.model_record(manifest, "uncensored-q6")
        q4 = model_backup.model_record(manifest, "uncensored-q4")
        whitehat = model_backup.model_record(manifest, "whitehat-q4")
        q8 = model_backup.model_record(manifest, "uncensored-q8")
        self.assertEqual(
            model_backup.SUPPORTED_MODEL_IDS,
            (
                "uncensored-q6",
                "uncensored-q4",
                "whitehat-q4",
                "uncensored-q8",
            ),
        )
        self.assertEqual(
            model_backup.DEFAULT_MODEL_IDS,
            ("uncensored-q6", "uncensored-q4"),
        )
        self.assertEqual(model_backup.DEFAULT_MODEL_IDS, model_backup.REQUIRED_MODEL_IDS)
        self.assertEqual(
            model_backup.OPTIONAL_MODEL_IDS,
            ("whitehat-q4", "uncensored-q8"),
        )
        self.assertEqual(q6["expected_size_bytes"], 22430999968)
        self.assertEqual(q4["expected_size_bytes"], 16810714528)
        self.assertEqual(
            q4["sha256"],
            "4c5e2db039e9325ac7724c8846c71356a24ad1cdfa28002d73ecb6be645f9675",
        )
        self.assertEqual(whitehat["expected_size_bytes"], 17559176608)
        self.assertEqual(q8["expected_size_bytes"], 29047084448)

    def test_powershell_wrapper_pins_cli_and_external_volume(self):
        source = (ROOT / "scripts" / "runpod-model-backup.ps1").read_text(encoding="utf-8")
        self.assertIn("huggingface-hub==1.28.0", source)
        self.assertIn("BACKUP_WIN", source)
        self.assertIn("outside the agent-writable project root", source)
        self.assertIn("--verify-only", source)
        self.assertIn("/usr/bin/python3", source)
        self.assertIn("HF_HUB_OFFLINE", source)
        self.assertIn("findmnt", source)
        self.assertIn("TrimEnd('\\')", source)
        self.assertIn("Assert-QwenModelBackupVolume", source)
        self.assertGreaterEqual(source.count("Assert-QwenPathHasNoReparsePoint"), 2)
        self.assertIn("--exec wslpath -a -u -- $projectRoot", source)
        self.assertIn(
            "[string[]]$Model = @('uncensored-q6', 'uncensored-q4')",
            source,
        )
        for model_id in model_backup.SUPPORTED_MODEL_IDS:
            self.assertIn(f"'{model_id}'", source)

    @unittest.skipUnless(os.name == "nt", "Windows WSL interop required")
    def test_windows_project_path_reaches_wslpath_without_backslash_loss(self):
        wsl = shutil.which("wsl.exe")
        if wsl is None:
            self.skipTest("WSL is not installed")
        result = subprocess.run(
            [
                wsl,
                "-d",
                "Ubuntu-24.04",
                "-u",
                "qwen-eval",
                "--exec",
                "wslpath",
                "-a",
                "-u",
                "--",
                str(ROOT),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = f"/mnt/{ROOT.drive[0].lower()}{ROOT.as_posix()[2:]}"
        self.assertEqual(result.stdout.strip(), expected)

    def test_powershell_canonical_paths_preserve_drive_root_and_reject_project_root(self):
        powershell = (
            shutil.which("powershell.exe")
            or shutil.which("pwsh")
            or shutil.which("powershell")
        )
        if powershell is None or os.name != "nt":
            self.skipTest("Windows PowerShell is required")
        module = ROOT / "scripts" / "ModelBackup.Common.psm1"
        command = (
            f"Import-Module '{str(module).replace("'", "''")}' -Force; "
            "$canonical = ConvertTo-QwenCanonicalWindowsPath -Path 'D:\\'; "
            "$insideRejected = $false; "
            "try { Resolve-QwenModelBackupRoot -BackupRoot "
            f"'{str(ROOT).replace("'", "''")}' -ProjectRoot "
            f"'{str(ROOT).replace("'", "''")}' -Required | Out-Null }} "
            "catch { $insideRejected = $true }; "
            "[pscustomobject]@{Canonical=$canonical;InsideRejected=$insideRejected} "
            "| ConvertTo-Json -Compress"
        )
        result = subprocess.run(
            [powershell, "-NoProfile", "-Command", command],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(payload["Canonical"], "D:\\")
        self.assertTrue(payload["InsideRejected"])

    @unittest.skipUnless(os.name == "nt", "Windows junction semantics required")
    def test_powershell_rejects_junction_backup_root(self):
        powershell = shutil.which("powershell.exe") or shutil.which("powershell")
        if powershell is None:
            self.skipTest("Windows PowerShell is required")
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            project = fixture / "project"
            target = fixture / "vault-target"
            junction = fixture / "vault-link"
            project.mkdir()
            target.mkdir()
            module = str(ROOT / "scripts" / "ModelBackup.Common.psm1").replace("'", "''")
            command = f"""
$ErrorActionPreference = 'Stop'
Import-Module '{module}' -Force
New-Item -ItemType Junction -Path '{str(junction).replace("'", "''")}' -Target '{str(target).replace("'", "''")}' | Out-Null
$rejected = $false
try {{ Resolve-QwenModelBackupRoot -BackupRoot '{str(junction).replace("'", "''")}' -ProjectRoot '{str(project).replace("'", "''")}' -Required | Out-Null }}
catch {{ $rejected = $_.Exception.Message -like '*reparse point*' }}
[pscustomobject]@{{Rejected=$rejected}} | ConvertTo-Json -Compress
"""
            result = subprocess.run(
                [powershell, "-NoProfile", "-Command", command],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout.strip().splitlines()[-1])
            self.assertTrue(payload["Rejected"])

    def test_powershell_volume_contract_rejects_fat_and_allows_exfat(self):
        source = (ROOT / "scripts" / "ModelBackup.Common.psm1").read_text(
            encoding="utf-8"
        )
        self.assertIn("@('FAT', 'FAT32')", source)
        self.assertIn("@('exFAT', 'NTFS', 'ReFS')", source)

    def test_ready_adoption_requires_exact_model_source_binding(self):
        powershell = (
            shutil.which("powershell.exe")
            or shutil.which("pwsh")
            or shutil.which("powershell")
        )
        if powershell is None:
            self.skipTest("PowerShell is required")
        module_path = str(ROOT / "scripts" / "ModelBackup.Common.psm1")
        if os.name != "nt" and Path(powershell).name.lower() == "powershell.exe":
            module_path = subprocess.run(
                ["wslpath", "-w", module_path],
                capture_output=True,
                text=True,
                timeout=10,
                check=True,
            ).stdout.strip()
        module = module_path.replace("'", "''")
        digest = "d" * 64
        command = f"""
Import-Module '{module}' -Force
$policy = 'content-addressed-hub-or-verified-local-v1'
$hubState = [pscustomobject]@{{model_source='hub';model_source_policy=$policy;model_backup_manifest_sha256=$null;model_id='uncensored-q6'}}
$hubSession = [pscustomobject]@{{ModelSource='hub';ModelSourcePolicy=$policy;LocalModelManifestSha256=$null;LocallySeededModels=@();ActiveModel='uncensored-q6'}}
$localState = [pscustomobject]@{{model_source='local-only';model_source_policy=$policy;model_backup_manifest_sha256='{digest}';model_id='uncensored-q6'}}
$localSession = [pscustomobject]@{{ModelSource='local-only';ModelSourcePolicy=$policy;LocalModelManifestSha256='{digest}';LocallySeededModels=@('uncensored-q6');ActiveModel='uncensored-q6'}}
$wrongStateModel = [pscustomobject]@{{model_source='local-only';model_source_policy=$policy;model_backup_manifest_sha256='{digest}';model_id='whitehat-q4'}}
$wrongSessionModel = [pscustomobject]@{{ModelSource='local-only';ModelSourcePolicy=$policy;LocalModelManifestSha256='{digest}';LocallySeededModels=@('uncensored-q6');ActiveModel='whitehat-q4'}}
$wrongHubStateModel = [pscustomobject]@{{model_source='hub';model_source_policy=$policy;model_backup_manifest_sha256=$null;model_id='whitehat-q4'}}
$wrongHubSessionModel = [pscustomobject]@{{ModelSource='hub';ModelSourcePolicy=$policy;LocalModelManifestSha256=$null;LocallySeededModels=@();ActiveModel='whitehat-q4'}}
[pscustomobject]@{{
  HubCannotSatisfyLocal = -not (Test-QwenReadyModelSourceBinding -ExistingState $hubState -ReadySession $hubSession -ExpectedModelSource local-only -ExpectedModelSourcePolicy $policy -ExpectedBackupManifestSha256 '{digest}' -RequiredModel uncensored-q6)
  ExactHubAccepted = Test-QwenReadyModelSourceBinding -ExistingState $hubState -ReadySession $hubSession -ExpectedModelSource hub -ExpectedModelSourcePolicy $policy -ExpectedBackupManifestSha256 $null -RequiredModel uncensored-q6
  ExactLocalAccepted = Test-QwenReadyModelSourceBinding -ExistingState $localState -ReadySession $localSession -ExpectedModelSource local-only -ExpectedModelSourcePolicy $policy -ExpectedBackupManifestSha256 '{digest}' -RequiredModel uncensored-q6
  MissingSeedRejected = -not (Test-QwenReadyModelSourceBinding -ExistingState $localState -ReadySession $localSession -ExpectedModelSource local-only -ExpectedModelSourcePolicy $policy -ExpectedBackupManifestSha256 '{digest}' -RequiredModel whitehat-q4)
  WrongStateModelRejected = -not (Test-QwenReadyModelSourceBinding -ExistingState $wrongStateModel -ReadySession $localSession -ExpectedModelSource local-only -ExpectedModelSourcePolicy $policy -ExpectedBackupManifestSha256 '{digest}' -RequiredModel uncensored-q6)
  WrongSessionModelRejected = -not (Test-QwenReadyModelSourceBinding -ExistingState $localState -ReadySession $wrongSessionModel -ExpectedModelSource local-only -ExpectedModelSourcePolicy $policy -ExpectedBackupManifestSha256 '{digest}' -RequiredModel uncensored-q6)
  WrongHubStateModelRejected = -not (Test-QwenReadyModelSourceBinding -ExistingState $wrongHubStateModel -ReadySession $hubSession -ExpectedModelSource hub -ExpectedModelSourcePolicy $policy -ExpectedBackupManifestSha256 $null -RequiredModel uncensored-q6)
  WrongHubSessionModelRejected = -not (Test-QwenReadyModelSourceBinding -ExistingState $hubState -ReadySession $wrongHubSessionModel -ExpectedModelSource hub -ExpectedModelSourcePolicy $policy -ExpectedBackupManifestSha256 $null -RequiredModel uncensored-q6)
}} | ConvertTo-Json -Compress
"""
        result = subprocess.run(
            [powershell, "-NoProfile", "-Command", command],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertTrue(payload["HubCannotSatisfyLocal"])
        self.assertTrue(payload["ExactHubAccepted"])
        self.assertTrue(payload["ExactLocalAccepted"])
        self.assertTrue(payload["MissingSeedRejected"])
        self.assertTrue(payload["WrongStateModelRejected"])
        self.assertTrue(payload["WrongSessionModelRejected"])
        self.assertTrue(payload["WrongHubStateModelRejected"])
        self.assertTrue(payload["WrongHubSessionModelRejected"])

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell is required")
    def test_powershell_volume_gate_executes_fat_reject_exfat_allow(self):
        powershell = shutil.which("powershell.exe") or shutil.which("powershell")
        if powershell is None:
            self.skipTest("Windows PowerShell is required")
        module = str(ROOT / "scripts" / "ModelBackup.Common.psm1").replace("'", "''")
        command = f"""
function global:Get-Volume {{
    [CmdletBinding()]
    param([string]$DriveLetter)
    [pscustomobject]@{{
        DriveLetter = $DriveLetter
        HealthStatus = 'Healthy'
        FileSystem = $global:FixtureFileSystem
    }}
}}
Import-Module '{module}' -Force
$global:FixtureFileSystem = 'FAT32'
$fatRejected = $false
try {{ Assert-QwenModelBackupVolume -CanonicalPath 'D:\\vault' | Out-Null }}
catch {{ $fatRejected = $true }}
$global:FixtureFileSystem = 'exFAT'
$exfat = Assert-QwenModelBackupVolume -CanonicalPath 'D:\\vault'
[pscustomobject]@{{
    FatRejected = $fatRejected
    ExfatAccepted = ([string]$exfat.FileSystem -eq 'exFAT')
}} | ConvertTo-Json -Compress
"""
        result = subprocess.run(
            [powershell, "-NoProfile", "-Command", command],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertTrue(payload["FatRejected"])
        self.assertTrue(payload["ExfatAccepted"])

    def test_powershell_contract_verifies_marker_size_and_sha(self):
        powershell = shutil.which("powershell.exe")
        if powershell is None and os.name == "nt":
            powershell = shutil.which("pwsh") or shutil.which("powershell")
        if powershell is None:
            self.skipTest("Windows PowerShell or WSL interop is required")
        with tempfile.TemporaryDirectory(dir=ROOT) as temporary:
            fixture = Path(temporary)
            project = fixture / "project"
            vault = fixture / "vault"
            config = project / "config"
            model_dir = vault / "uncensored-q6"
            config.mkdir(parents=True)
            model_dir.mkdir(parents=True)
            model_bytes = b"model-backup-contract"
            projector_bytes = b"projector-backup-contract"
            manifest = {
                "schema_version": 1,
                "models": [
                    {
                        "id": "uncensored-q6",
                        "repo_id": "owner/repo",
                        "revision": "b" * 40,
                        "filename": "model.gguf",
                        "expected_size_bytes": len(model_bytes),
                        "sha256": hashlib.sha256(model_bytes).hexdigest(),
                        "vision_projector": {
                            "filename": "projector.gguf",
                            "expected_size_bytes": len(projector_bytes),
                            "sha256": hashlib.sha256(projector_bytes).hexdigest(),
                        },
                    }
                ],
            }
            manifest_path = config / "models.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_sha = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
            snapshot_dir = vault / "config"
            snapshot_dir.mkdir(parents=True)
            (snapshot_dir / f"models.{manifest_sha}.json").write_bytes(
                manifest_path.read_bytes()
            )
            (model_dir / "model.gguf").write_bytes(model_bytes)
            projector_path = model_dir / "projector.gguf"
            projector_path.write_bytes(projector_bytes)
            acquisition = {
                "schema_version": 1,
                "model_id": "uncensored-q6",
                "repo_id": "owner/repo",
                "requested_revision": "b" * 40,
                "resolved_revision": "b" * 40,
                "artifacts": [
                    {
                        "role": "model",
                        "filename": "model.gguf",
                        "size_bytes": len(model_bytes),
                        "sha256": hashlib.sha256(model_bytes).hexdigest(),
                    },
                    {
                        "role": "vision_projector",
                        "filename": "projector.gguf",
                        "size_bytes": len(projector_bytes),
                        "sha256": hashlib.sha256(projector_bytes).hexdigest(),
                    },
                ],
                "provenance_files": [],
            }
            acquisition_path = model_dir / "provenance" / "acquisition.json"
            acquisition_path.parent.mkdir()
            acquisition_path.write_text(json.dumps(acquisition), encoding="utf-8")
            acquisition_sha = hashlib.sha256(acquisition_path.read_bytes()).hexdigest()
            verification = {
                "schema_version": 1,
                "model_id": "uncensored-q6",
                "repo_id": "owner/repo",
                "revision": "b" * 40,
                "manifest_sha256": manifest_sha,
                "acquisition_relative_path": "provenance/acquisition.json",
                "acquisition_sha256": acquisition_sha,
                "artifacts": acquisition["artifacts"],
            }
            verification_path = model_dir / "verification.json"
            verification_path.write_text(json.dumps(verification), encoding="utf-8")
            verification_sha = hashlib.sha256(verification_path.read_bytes()).hexdigest()
            complete_path = model_dir / ".complete.json"
            complete = {
                "schema_version": 3,
                "complete": True,
                "model_id": "uncensored-q6",
                "repo_id": "owner/repo",
                "revision": "b" * 40,
                "manifest_sha256": manifest_sha,
                "acquisition_relative_path": "provenance/acquisition.json",
                "acquisition_sha256": acquisition_sha,
                "verification_relative_path": "verification.json",
                "verification_sha256": verification_sha,
                "artifacts": acquisition["artifacts"],
            }
            complete_path.write_text(json.dumps(complete), encoding="utf-8")

            windows_powershell_from_wsl = (
                os.name != "nt" and Path(powershell).name.lower() == "powershell.exe"
            )

            def powershell_path(path: Path) -> str:
                if windows_powershell_from_wsl:
                    converted = subprocess.run(
                        ["wslpath", "-w", str(path)],
                        capture_output=True,
                        text=True,
                        timeout=10,
                        check=True,
                    )
                    return converted.stdout.strip()
                return str(path)

            def ps_literal(path: Path) -> str:
                return powershell_path(path).replace("'", "''")

            harness = fixture / "verify.ps1"
            harness.write_text(
                f"""
$ErrorActionPreference = 'Stop'
Import-Module '{ps_literal(ROOT / 'scripts' / 'ModelBackup.Common.psm1')}' -Force
$result = Assert-QwenModelBackup -ProjectRoot '{ps_literal(project)}' -BackupRoot '{ps_literal(vault)}' -Model uncensored-q6
$result | ConvertTo-Json -Depth 8 -Compress
""".strip()
                + "\n",
                encoding="utf-8",
            )
            valid = subprocess.run(
                [powershell, "-NoProfile", "-File", powershell_path(harness)],
                cwd=ROOT,
                capture_output=True,
                timeout=30,
                check=False,
            )
            valid_stdout = valid.stdout.decode("utf-8", errors="replace")
            valid_stderr = valid.stderr.decode("utf-8", errors="replace")
            self.assertEqual(valid.returncode, 0, valid_stderr)
            json_lines = [
                line.strip()
                for line in valid_stdout.splitlines()
                if line.strip().startswith("{") and line.strip().endswith("}")
            ]
            self.assertTrue(json_lines, repr(valid_stdout))
            self.assertEqual(json.loads(json_lines[-1])["ModelId"], "uncensored-q6")

            complete["schema_version"] = 2
            complete_path.write_text(json.dumps(complete), encoding="utf-8")
            legacy_v2 = subprocess.run(
                [powershell, "-NoProfile", "-File", powershell_path(harness)],
                cwd=ROOT,
                capture_output=True,
                timeout=30,
                check=False,
            )
            self.assertNotEqual(legacy_v2.returncode, 0)
            complete["schema_version"] = 3
            complete_path.write_text(json.dumps(complete), encoding="utf-8")

            fabricated_verification = dict(verification)
            fabricated_verification.pop("artifacts")
            verification_path.write_text(
                json.dumps(fabricated_verification), encoding="utf-8"
            )
            complete["verification_sha256"] = hashlib.sha256(
                verification_path.read_bytes()
            ).hexdigest()
            complete_path.write_text(json.dumps(complete), encoding="utf-8")
            incomplete_verification = subprocess.run(
                [powershell, "-NoProfile", "-File", powershell_path(harness)],
                cwd=ROOT,
                capture_output=True,
                timeout=30,
                check=False,
            )
            self.assertNotEqual(incomplete_verification.returncode, 0)

            verification_path.write_text(json.dumps(verification), encoding="utf-8")
            complete["verification_sha256"] = hashlib.sha256(
                verification_path.read_bytes()
            ).hexdigest()
            complete_path.write_text(json.dumps(complete), encoding="utf-8")

            fabricated_acquisition = dict(acquisition)
            fabricated_acquisition.pop("artifacts")
            acquisition_path.write_text(
                json.dumps(fabricated_acquisition), encoding="utf-8"
            )
            verification["acquisition_sha256"] = hashlib.sha256(
                acquisition_path.read_bytes()
            ).hexdigest()
            verification_path.write_text(json.dumps(verification), encoding="utf-8")
            complete["acquisition_sha256"] = verification["acquisition_sha256"]
            complete["verification_sha256"] = hashlib.sha256(
                verification_path.read_bytes()
            ).hexdigest()
            complete_path.write_text(json.dumps(complete), encoding="utf-8")
            incomplete_acquisition = subprocess.run(
                [powershell, "-NoProfile", "-File", powershell_path(harness)],
                cwd=ROOT,
                capture_output=True,
                timeout=30,
                check=False,
            )
            self.assertNotEqual(incomplete_acquisition.returncode, 0)

            acquisition_path.write_text(json.dumps(acquisition), encoding="utf-8")
            acquisition_sha = hashlib.sha256(acquisition_path.read_bytes()).hexdigest()
            verification["acquisition_sha256"] = acquisition_sha
            verification_path.write_text(json.dumps(verification), encoding="utf-8")
            complete["acquisition_sha256"] = acquisition_sha
            complete["verification_sha256"] = hashlib.sha256(
                verification_path.read_bytes()
            ).hexdigest()
            complete_path.write_text(json.dumps(complete), encoding="utf-8")

            malformed_provenance = dict(acquisition)
            malformed_provenance["provenance_files"] = [
                {
                    "filename": "README.md",
                    "relative_path": "provenance/README.md",
                    "size_bytes": True,
                    "sha256": hashlib.sha256(b"").hexdigest(),
                }
            ]
            acquisition_path.write_text(
                json.dumps(malformed_provenance), encoding="utf-8"
            )
            malformed_acquisition_sha = hashlib.sha256(
                acquisition_path.read_bytes()
            ).hexdigest()
            verification["acquisition_sha256"] = malformed_acquisition_sha
            verification_path.write_text(json.dumps(verification), encoding="utf-8")
            complete["acquisition_sha256"] = malformed_acquisition_sha
            complete["verification_sha256"] = hashlib.sha256(
                verification_path.read_bytes()
            ).hexdigest()
            complete_path.write_text(json.dumps(complete), encoding="utf-8")
            malformed_provenance_result = subprocess.run(
                [powershell, "-NoProfile", "-File", powershell_path(harness)],
                cwd=ROOT,
                capture_output=True,
                timeout=30,
                check=False,
            )
            self.assertNotEqual(malformed_provenance_result.returncode, 0)

            acquisition_path.write_text(json.dumps(acquisition), encoding="utf-8")
            acquisition_sha = hashlib.sha256(acquisition_path.read_bytes()).hexdigest()
            verification["acquisition_sha256"] = acquisition_sha
            verification_path.write_text(json.dumps(verification), encoding="utf-8")
            complete["acquisition_sha256"] = acquisition_sha
            complete["verification_sha256"] = hashlib.sha256(
                verification_path.read_bytes()
            ).hexdigest()
            complete_path.write_text(json.dumps(complete), encoding="utf-8")

            projector_path.write_bytes(b"X" + projector_bytes[1:])
            corrupted = subprocess.run(
                [powershell, "-NoProfile", "-File", powershell_path(harness)],
                cwd=ROOT,
                capture_output=True,
                timeout=30,
                check=False,
            )
            self.assertNotEqual(corrupted.returncode, 0)
            self.assertIn(
                "SHA-256", corrupted.stderr.decode("utf-8", errors="replace")
            )


if __name__ == "__main__":
    unittest.main()

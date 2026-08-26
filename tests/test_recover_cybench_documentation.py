from __future__ import annotations

import asyncio
from contextlib import redirect_stdout
from dataclasses import replace
from datetime import datetime, timezone
import io
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

from inspect_ai.model import (
    ChatMessageAssistant,
    ChatMessageSystem,
    ChatMessageUser,
)

from scripts import recover_cybench_documentation as recovery


TARGET = "CYBENCH{unit-test-secret}"


def fake_log(*, samples: int = 1, report: str = "", status: str = "error"):
    solution_messages = [
        ChatMessageSystem(content="Loesungssystem", id="system-1"),
        ChatMessageUser(content="Urspruengliche Aufgabe", id="message-1"),
        ChatMessageUser(content="Deutsche Erinnerung", id="message-2"),
        ChatMessageAssistant(content="Veralteter Versuch", id="message-3"),
        ChatMessageUser(
            content="Aktuelle Zusammenfassung",
            id="message-4",
            metadata={"summary": True},
        ),
        ChatMessageAssistant(content="Letzter Stand", id="message-5"),
    ]
    messages = [
        *solution_messages,
        ChatMessageSystem(content="Dokumentationssystem", id="doc-system"),
        ChatMessageUser(
            content=(
                f"{recovery.DOCUMENTATION_HANDOFF}\n\n"
                "ALTER_FEHLGESCHLAGENER_HANDOFF"
            ),
            id="doc-handoff",
        ),
        ChatMessageAssistant(
            content="Fehlgeschlagene Dokumentation",
            id="doc-assistant",
        ),
    ]
    result = []
    for index in range(samples):
        result.append(
            SimpleNamespace(
                id=f"challenge-{index}",
                uuid=f"uuid-{index}",
                target=TARGET,
                messages=list(messages),
                scores={"includes": SimpleNamespace(value="C")},
                store={
                    "cybench.documentation_report": report,
                    "cybench.solution_phase": {
                        "status": "agent_terminated",
                        "budget_seconds": 7200,
                        "elapsed_seconds": 123.5,
                        "started_at_utc": "2026-08-25T00:00:00+00:00",
                        "completed_at_utc": "2026-08-25T00:02:03+00:00",
                        "message_count": len(solution_messages),
                        "non_system_message_count": 5,
                        "message_ids": [
                            "message-1",
                            "message-2",
                            "message-3",
                            "message-4",
                            "message-5",
                        ],
                    },
                    "cybench.documentation_phase": {
                        "status": status,
                        "budget_seconds": 1800,
                        "elapsed_seconds": 4.5,
                        "started_at_utc": "2026-08-25T00:02:03+00:00",
                        "completed_at_utc": "2026-08-25T00:02:08+00:00",
                        "error": "ProviderError: raw secret-bearing original text",
                    },
                },
            )
        )
    return SimpleNamespace(
        eval=SimpleNamespace(metadata={"official_scorer": "includes"}),
        metadata={},
        samples=result,
    )


class PrepareRecoveryTests(unittest.TestCase):
    def test_uses_exact_latest_compaction_window(self) -> None:
        prepared = recovery.prepare_recovery(
            fake_log(),
            source_eval_sha256="a" * 64,
        )

        self.assertEqual(prepared.context_source, "latest_compaction_window")
        self.assertEqual(prepared.source_message_count, 9)
        self.assertEqual(prepared.solution_message_count, 6)
        self.assertEqual(
            prepared.solution_message_ids,
            [
                "message-1",
                "message-2",
                "message-3",
                "message-4",
                "message-5",
            ],
        )
        self.assertEqual(prepared.excluded_documentation_message_count, 3)
        self.assertEqual(prepared.excluded_documentation_handoff_count, 1)
        self.assertEqual(prepared.context_message_count, 2)
        self.assertEqual(len(prepared.input_messages), 3)
        self.assertEqual(
            prepared.input_message_ids,
            ["message-4", "message-5"],
        )
        recovery_input = "\n".join(
            str(message.content) for message in prepared.input_messages
        )
        self.assertNotIn("Veralteter Versuch", recovery_input)
        self.assertNotIn("ALTER_FEHLGESCHLAGENER_HANDOFF", recovery_input)
        self.assertNotIn("Fehlgeschlagene Dokumentation", recovery_input)
        self.assertEqual(
            sum(
                recovery.is_documentation_handoff(message)
                for message in prepared.input_messages
            ),
            1,
        )
        self.assertIn(TARGET, prepared.sensitive_strings)

    def test_rejects_missing_reordered_or_duplicate_declared_solution_ids(self) -> None:
        cases = {
            "missing": [
                "message-1",
                "message-2",
                "message-3",
                "message-4",
                "message-404",
            ],
            "reordered": [
                "message-2",
                "message-1",
                "message-3",
                "message-4",
                "message-5",
            ],
            "duplicate": [
                "message-1",
                "message-2",
                "message-3",
                "message-4",
                "message-4",
            ],
        }
        for name, message_ids in cases.items():
            with self.subTest(name=name):
                log = fake_log()
                log.samples[0].store["cybench.solution_phase"][
                    "message_ids"
                ] = message_ids
                expected = (
                    "contains duplicates"
                    if name == "duplicate"
                    else "chronological prefix"
                )
                with self.assertRaisesRegex(
                    recovery.RecoveryValidationError,
                    expected,
                ):
                    recovery.prepare_recovery(
                        log,
                        source_eval_sha256="a" * 64,
                    )

    def test_rejects_missing_or_nonunique_ids_in_the_solution_prefix(self) -> None:
        missing_id_log = fake_log()
        object.__setattr__(missing_id_log.samples[0].messages[5], "id", None)
        with self.assertRaisesRegex(
            recovery.RecoveryValidationError,
            "without an ID",
        ):
            recovery.prepare_recovery(
                missing_id_log,
                source_eval_sha256="a" * 64,
            )

        duplicate_in_suffix_log = fake_log()
        duplicate_in_suffix_log.samples[0].messages[-1] = ChatMessageAssistant(
            content="Fehlgeschlagene Dokumentation",
            id="message-5",
        )
        with self.assertRaisesRegex(
            recovery.RecoveryValidationError,
            "duplicated in the full sample",
        ):
            recovery.prepare_recovery(
                duplicate_in_suffix_log,
                source_eval_sha256="a" * 64,
            )

    def test_requires_exactly_one_selected_sample(self) -> None:
        with self.assertRaisesRegex(
            recovery.RecoveryValidationError,
            "exactly one selected sample",
        ):
            recovery.prepare_recovery(
                fake_log(samples=2),
                source_eval_sha256="a" * 64,
            )

        prepared = recovery.prepare_recovery(
            fake_log(samples=2),
            source_eval_sha256="a" * 64,
            sample_uuid="uuid-1",
        )
        self.assertEqual(prepared.sample_id, "challenge-1")

    def test_refuses_nonempty_or_nonerror_original_documentation(self) -> None:
        with self.assertRaisesRegex(
            recovery.RecoveryValidationError,
            "report is not empty",
        ):
            recovery.prepare_recovery(
                fake_log(report="existing"),
                source_eval_sha256="a" * 64,
            )
        with self.assertRaisesRegex(
            recovery.RecoveryValidationError,
            "status is not 'error'",
        ):
            recovery.prepare_recovery(
                fake_log(status="agent_terminated"),
                source_eval_sha256="a" * 64,
            )


class ExecuteRecoveryTests(unittest.TestCase):
    def test_direct_model_config_input_and_output_redaction(self) -> None:
        prepared = recovery.prepare_recovery(
            fake_log(),
            source_eval_sha256="b" * 64,
        )
        calls: dict[str, object] = {}

        class FakeModel:
            async def __aenter__(self):
                calls["entered"] = True
                return self

            async def __aexit__(self, *_args):
                calls["exited"] = True

            async def generate(self, **kwargs):
                calls.update(kwargs)
                return SimpleNamespace(
                    stop_reason="stop",
                    completion=(
                        "<think>private chain</think>\n"
                        f"Ergebnis\nAntwort: {TARGET}"
                    ),
                )

        def fake_model_factory(model_id: str):
            calls["model_id"] = model_id
            return FakeModel()

        utc_values = iter(
            [
                datetime(2026, 8, 25, 1, 0, tzinfo=timezone.utc),
                datetime(2026, 8, 25, 1, 0, 2, tzinfo=timezone.utc),
            ]
        )
        monotonic_values = iter([10.0, 12.5])
        record = asyncio.run(
            recovery.execute_recovery(
                prepared,
                model_id="openai-api/llamacpp/qwen-test",
                model_factory=fake_model_factory,
                utc_now=lambda: next(utc_values),
                monotonic_fn=lambda: next(monotonic_values),
            )
        )

        self.assertEqual(calls["model_id"], "openai-api/llamacpp/qwen-test")
        self.assertTrue(calls["entered"])
        self.assertTrue(calls["exited"])
        self.assertEqual(calls["tools"], [])
        self.assertEqual(calls["tool_choice"], "none")
        model_input = calls["input"]
        self.assertEqual(len(model_input), len(prepared.input_messages) + 1)
        self.assertIsInstance(model_input[0], ChatMessageSystem)
        self.assertIn(recovery.DOCUMENTATION_INSTRUCTION, model_input[0].content)
        self.assertIn(recovery.DIRECT_REPORT_INSTRUCTION, model_input[0].content)
        config = calls["config"]
        self.assertEqual(config.temperature, 0)
        self.assertEqual(config.max_tokens, 8192)
        self.assertEqual(config.reasoning_effort, "none")
        self.assertEqual(
            config.extra_body,
            {"chat_template_kwargs": {"enable_thinking": False}},
        )
        self.assertEqual(record["provenance"], recovery.PROVENANCE)
        self.assertEqual(
            record["schema_version"], recovery.RECOVERY_SCHEMA_VERSION
        )
        self.assertEqual(record["schema_version"], 3)
        self.assertFalse(record["canonical_documentation_timing"])
        self.assertEqual(
            record["recovery"]["execution_mode"], "direct_model_report"
        )
        self.assertEqual(record["recovery"]["limit_seconds"], 1800)
        self.assertEqual(
            record["recovery"]["configured_max_output_tokens"], 8192
        )
        self.assertEqual(record["recovery"]["stop_reason"], "stop")
        self.assertEqual(record["recovery"]["elapsed_seconds"], 2.5)
        self.assertEqual(record["recovery"]["status"], "agent_terminated")
        self.assertEqual(record["input"]["source_message_count"], 9)
        self.assertEqual(record["input"]["solution_message_count"], 6)
        self.assertEqual(record["input"]["excluded_documentation_message_count"], 3)
        self.assertEqual(record["input"]["excluded_documentation_handoff_count"], 1)
        self.assertEqual(record["input"]["recovery_handoff_count"], 1)
        self.assertEqual(
            record["input"]["solution_message_ids"],
            [
                "message-1",
                "message-2",
                "message-3",
                "message-4",
                "message-5",
            ],
        )
        serialized = json.dumps(record)
        self.assertNotIn(TARGET, serialized)
        self.assertNotIn("private chain", serialized)
        self.assertNotIn("raw secret-bearing original text", serialized)
        self.assertIn("[REDACTED_ANSWER]", record["report"])

    def test_execute_refuses_more_than_one_recovery_handoff(self) -> None:
        prepared = recovery.prepare_recovery(
            fake_log(),
            source_eval_sha256="b" * 64,
        )
        corrupted = replace(
            prepared,
            input_messages=[
                *prepared.input_messages,
                ChatMessageUser(
                    content=f"{recovery.DOCUMENTATION_HANDOFF}\n\nDoppelt"
                ),
            ],
        )
        with self.assertRaisesRegex(
            recovery.RecoveryValidationError,
            "exactly one",
        ):
            asyncio.run(
                recovery.execute_recovery(
                    corrupted,
                    model_id="openai-api/llamacpp/qwen-test",
                    model_factory=lambda _model_id: self.fail(
                        "model must not be called"
                    ),
                )
            )

    def test_provider_error_records_only_exception_class(self) -> None:
        prepared = recovery.prepare_recovery(
            fake_log(),
            source_eval_sha256="c" * 64,
        )

        class FailingModel:
            async def __aenter__(self):
                return self

            async def __aexit__(self, *_args):
                return None

            async def generate(self, **_kwargs):
                raise RuntimeError("Bearer api-key-must-never-be-written")

        record = asyncio.run(
            recovery.execute_recovery(
                prepared,
                model_id="openai-api/llamacpp/qwen-test",
                model_factory=lambda _model_id: FailingModel(),
            )
        )
        serialized = json.dumps(record)
        self.assertEqual(record["recovery"]["status"], "error")
        self.assertEqual(record["recovery"]["error"], "RuntimeError")
        self.assertEqual(record["report"], "")
        self.assertNotIn("api-key-must-never-be-written", serialized)

    def test_expired_asyncio_timeout_is_the_only_time_limit_status(self) -> None:
        prepared = recovery.prepare_recovery(
            fake_log(),
            source_eval_sha256="d" * 64,
        )
        seen: dict[str, object] = {}

        class ExpiredTimeout:
            async def __aenter__(self):
                raise TimeoutError("simulated deadline")

            async def __aexit__(self, *_args):
                return None

            def expired(self):
                return True

        def timeout_factory(seconds: float):
            seen["seconds"] = seconds
            return ExpiredTimeout()

        record = asyncio.run(
            recovery.execute_recovery(
                prepared,
                model_id="openai-api/llamacpp/qwen-test",
                model_factory=lambda _model_id: self.fail(
                    "model must not be entered after timeout"
                ),
                timeout_factory=timeout_factory,
            )
        )
        self.assertEqual(seen["seconds"], 1800)
        self.assertEqual(record["recovery"]["status"], "limit_reached")
        self.assertEqual(record["recovery"]["limit_type"], "time")
        self.assertIsNone(record["recovery"]["error"])
        self.assertIsNone(record["recovery"]["stop_reason"])
        self.assertEqual(record["report"], "")

    def test_max_tokens_is_truncated_and_main_writes_with_nonzero_exit(self) -> None:
        prepared = recovery.prepare_recovery(
            fake_log(),
            source_eval_sha256="e" * 64,
        )

        class TruncatedModel:
            async def __aenter__(self):
                return self

            async def __aexit__(self, *_args):
                return None

            async def generate(self, **_kwargs):
                return SimpleNamespace(
                    stop_reason="max_tokens",
                    completion="Ergebnis\nDer Bericht ist abgeschnitten.",
                )

        record = asyncio.run(
            recovery.execute_recovery(
                prepared,
                model_id="openai-api/llamacpp/qwen-test",
                model_factory=lambda _model_id: TruncatedModel(),
            )
        )
        self.assertEqual(record["recovery"]["status"], "output_truncated")
        self.assertEqual(record["recovery"]["stop_reason"], "max_tokens")
        self.assertTrue(record["report"])

        with tempfile.TemporaryDirectory() as temporary_directory:
            source = Path(temporary_directory, "source.eval")
            output = Path(temporary_directory, "recovery.json")
            source.write_bytes(b"stable")
            prepared_for_source = replace(
                prepared,
                source_eval_sha256=recovery.file_sha256(source),
            )

            def return_record(coroutine):
                coroutine.close()
                return record

            with (
                patch.object(
                    recovery,
                    "load_prepared",
                    return_value=prepared_for_source,
                ),
                patch.object(recovery.asyncio, "run", side_effect=return_record),
                redirect_stdout(io.StringIO()),
            ):
                exit_code = recovery.main(
                    [
                        "--source",
                        str(source),
                        "--output",
                        str(output),
                        "--execute",
                        "--model",
                        "openai-api/llamacpp/qwen-test",
                    ]
                )
            self.assertEqual(exit_code, 1)
            self.assertTrue(output.exists())
            written = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(written["recovery"]["status"], "output_truncated")


class DryRunAndWriteTests(unittest.TestCase):
    def test_dry_run_does_not_call_model_or_write_sidecar(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = Path(temporary_directory, "source.eval")
            output = Path(temporary_directory, "recovery.json")
            original = b"stable eval bytes"
            source.write_bytes(original)
            captured = io.StringIO()
            with (
                patch.object(recovery, "read_eval_log", return_value=fake_log()),
                patch.object(
                    recovery,
                    "execute_recovery",
                    side_effect=AssertionError("model path called"),
                ),
                redirect_stdout(captured),
            ):
                exit_code = recovery.main(
                    [
                        "--source",
                        str(source),
                        "--output",
                        str(output),
                        "--dry-run",
                    ]
                )

            summary = json.loads(captured.getvalue())
            self.assertEqual(exit_code, 0)
            self.assertTrue(summary["validation_ok"])
            self.assertEqual(summary["selected_sample_count"], 1)
            self.assertEqual(summary["source_message_count"], 9)
            self.assertEqual(summary["solution_message_count"], 6)
            self.assertEqual(summary["validated_solution_message_id_count"], 5)
            self.assertEqual(summary["excluded_documentation_message_count"], 3)
            self.assertEqual(summary["excluded_documentation_handoff_count"], 1)
            self.assertEqual(summary["recovery_handoff_count"], 1)
            self.assertNotIn("sample", summary)
            self.assertNotIn("official_score", summary)
            self.assertFalse(output.exists())
            self.assertEqual(source.read_bytes(), original)

    def test_atomic_writer_refuses_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory, "recovery.json")
            recovery.write_json_atomic(output, {"safe": True})
            self.assertEqual(
                json.loads(output.read_text(encoding="utf-8")),
                {"safe": True},
            )
            with self.assertRaisesRegex(
                recovery.RecoveryValidationError,
                "overwrite",
            ):
                recovery.write_json_atomic(output, {"safe": False})


if __name__ == "__main__":
    unittest.main()

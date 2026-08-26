from __future__ import annotations

from contextlib import redirect_stdout
from collections.abc import Callable
import io
from hashlib import sha256
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from scripts import cybench_run_health
from evals.cybench import (
    AGENT_POLICY_NEUTRAL,
    DOCUMENTATION_PIPELINE_ID,
    DOCUMENTATION_PIPELINE_VERSION,
    agent_policy_prompt_sha256,
)
from evals.cybench_toolchains import get_agent_toolchain


MODEL_API_TIMEOUT_POLICY = "phase-limit-owned-v1"
MODEL_API_CLIENT_TIMEOUT_SECONDS = 7_500


def current_toolchain_metadata() -> dict[str, object]:
    toolchain = get_agent_toolchain()
    return {
        "agent_toolchain_id": toolchain.identifier,
        "agent_toolchain_image": toolchain.agent_image,
        "agent_toolchain_image_digest": toolchain.agent_image.rsplit("@", 1)[1],
        "agent_toolchain_manifest_sha256": toolchain.manifest_sha256,
        "agent_toolchain_runtime_installation": False,
    }


def run_contract_metadata() -> dict[str, object]:
    return {
        "official_scorer": "includes",
        "agent_policy_version": "baseline-v1",
        "model_api_timeout_policy": MODEL_API_TIMEOUT_POLICY,
        "model_api_client_timeout_seconds": MODEL_API_CLIENT_TIMEOUT_SECONDS,
        "tool_output_max_bytes": 16_384,
        "context_management": "summary_compaction",
        "context_compaction_threshold_tokens": 160_000,
        "context_compaction_summary_max_tokens": 4_096,
        "context_compaction_summary_max_attempts": 2,
        "context_compaction_summary_completion": "best_nonempty_after_repair",
        "context_compaction_summary_retry_scope": "draft_only_when_available",
        "context_compaction_summary_priority": "next_steps_first",
        "context_compaction_summary_reasoning": "disabled",
        "model_context_tokens": 262_144,
    }


def canonical_report() -> str:
    return "\n".join(
        f"## {heading}\nBeobachtbare Evidenz zu diesem Abschnitt."
        for heading in cybench_run_health.DOCUMENTATION_HEADINGS
    )


def canonical_handoff() -> str:
    return (
        f"{cybench_run_health.DOCUMENTATION_HANDOFF_TEXT}\n\n"
        "Der Loesungsagent wurde beendet."
    )


def valid_solution_phase() -> dict[str, object]:
    return {
        "status": "agent_terminated",
        "limit_type": None,
        "limit_message": None,
        "budget_seconds": 7_200,
        "elapsed_seconds": 600.0,
        "budget_fraction": 0.083333,
        "overrun_seconds": 0.0,
        "started_at_utc": "2026-08-25T00:00:00Z",
        "completed_at_utc": "2026-08-25T00:10:00Z",
        "message_count": 3,
        "non_system_message_count": 2,
        "message_ids": ["solution-input", "solution-output"],
    }


def valid_documentation_phase(metadata: dict[str, object]) -> dict[str, object]:
    return {
        "status": "agent_terminated",
        "limit_type": None,
        "limit_message": None,
        "error": None,
        "documentation_pipeline_id": metadata.get("documentation_pipeline_id"),
        "documentation_pipeline_version": metadata.get(
            "documentation_pipeline_version"
        ),
        "budget_seconds": 1_800,
        "elapsed_seconds": 600.0,
        "budget_fraction": 0.333333,
        "overrun_seconds": 0.0,
        "started_at_utc": "2026-08-25T00:10:00Z",
        "completed_at_utc": "2026-08-25T00:20:00Z",
        "input_message_count": 4,
        "input_context_source": "full_solution_transcript",
        "solution_message_count": 3,
        "history_messages_omitted": 0,
        "output_message_count": 2,
        "new_message_count": 2,
        "appended_message_count": 3,
        "stage_order": list(
            cybench_run_health.ITERATIVE_DOCUMENTATION_STAGE_ORDER
        ),
        "stage_call_count": 3,
        "max_output_tokens_per_call": 4_096,
        "final_report_validated": True,
        "external_work_state_key": "cybench.documentation_work",
    }


def valid_documentation_work(
    metadata: dict[str, object],
    report: str,
) -> dict[str, object]:
    stage_order = list(
        cybench_run_health.ITERATIVE_DOCUMENTATION_STAGE_ORDER
    )
    base_stage = {
        "status": "completed",
        "attempts": 1,
        "max_output_tokens": 4_096,
    }
    return {
        "documentation_pipeline_id": metadata.get("documentation_pipeline_id"),
        "documentation_pipeline_version": metadata.get(
            "documentation_pipeline_version"
        ),
        "stage_order": stage_order,
        "max_output_tokens_per_call": 4_096,
        "accepted_report": True,
        "stages": {
            "evidence_extraction": dict(base_stage),
            "section_drafts": dict(base_stage),
            "final_synthesis": {
                **base_stage,
                "accepted_report_sha256": sha256(
                    report.encode("utf-8")
                ).hexdigest(),
                "accepted_source": "initial_submission",
                "submit_tool_only": True,
            },
        },
    }


def canonical_messages(report: str) -> list[dict[str, object]]:
    return [
        {"id": "solution-system", "role": "system", "content": "Solve policy"},
        {"id": "solution-input", "role": "user", "content": "Task"},
        {"id": "solution-output", "role": "assistant", "content": "Work"},
        {"id": "documentation-system", "role": "system", "content": "Doc policy"},
        {
            "id": "documentation-handoff",
            "role": "user",
            "content": (
                canonical_handoff()
            ),
        },
        {
            "id": "documentation-output",
            "role": "assistant",
            "content": report,
        },
    ]


def compaction_text(
    sections: tuple[str, ...] = cybench_run_health.COMPACTION_REQUIRED_SECTIONS,
) -> str:
    payload = "\n\n".join(
        f"## {section}\nBelegter Inhalt zu diesem Abschnitt."
        for section in sections
    )
    return (
        f"{cybench_run_health.COMPACTION_PREFIX}\n\n"
        "Die bisherige Arbeit wurde zusammengefasst.\n\n"
        f"{cybench_run_health.COMPACTION_OPEN}\n{payload}\n"
        f"{cybench_run_health.COMPACTION_CLOSE}\n\n"
        f"{cybench_run_health.COMPACTION_CONTINUATION}"
    )


def compaction_metadata(
    *,
    sections: tuple[str, ...] = cybench_run_health.COMPACTION_REQUIRED_SECTIONS,
) -> dict[str, object]:
    return {
        "summary": True,
        "summary_generation_attempts": 1,
        "summary_max_output_tokens": 4096,
        "summary_reasoning_disabled": True,
        "summary_complete": True,
        "summary_forced_accept": False,
        "summary_sections_present": list(sections),
    }


def compaction_event(
    *,
    uuid: str,
    timestamp: str,
) -> dict[str, object]:
    return {
        "uuid": uuid,
        "event": "compaction",
        "type": "summary",
        "timestamp": timestamp,
        "tokens_before": 160_100,
        "tokens_after": 4_000,
        "metadata": {
            "strategy": "GermanCompactionSummary",
            "trigger": "threshold",
            "messages_before": 20,
            "messages_after": 3,
        },
    }


def compacted_solution_sample(
    solution_non_system: list[dict[str, object]],
    events: list[dict[str, object]],
) -> dict[str, object]:
    metadata = {
        "documentation_pipeline_id": DOCUMENTATION_PIPELINE_ID,
        "documentation_pipeline_version": DOCUMENTATION_PIPELINE_VERSION,
    }
    report = canonical_report()
    solution_messages: list[dict[str, object]] = [
        {"id": "solve-system", "role": "system", "content": "Policy"},
        *solution_non_system,
    ]
    context_count, context_source, omitted = (
        cybench_run_health._expected_documentation_context(solution_messages)
    )
    solution_phase = valid_solution_phase()
    solution_phase.update(
        {
            "message_count": len(solution_messages),
            "non_system_message_count": len(solution_non_system),
            "message_ids": [
                str(message["id"]) for message in solution_non_system
            ],
        }
    )
    documentation_phase = valid_documentation_phase(metadata)
    documentation_phase.update(
        {
            "input_message_count": context_count + 2,
            "input_context_source": context_source,
            "solution_message_count": len(solution_messages),
            "history_messages_omitted": omitted,
            "output_message_count": 2,
        }
    )
    return {
        "id": "sample-1",
        "completed_at": "2026-08-25T00:20:00Z",
        "store": {
            "cybench.solution_phase": solution_phase,
            "cybench.documentation_phase": documentation_phase,
            "cybench.documentation_report": report,
            "cybench.documentation_work": valid_documentation_work(
                metadata,
                report,
            ),
        },
        "messages": [
            *solution_messages,
            {"id": "doc-system", "role": "system", "content": "Doc policy"},
            {
                "id": "doc-handoff",
                "role": "user",
                "content": canonical_handoff(),
            },
            {"id": "doc-output", "role": "assistant", "content": report},
        ],
        "events": events,
    }


def valid_sample(
    metadata: dict[str, object],
    *,
    documentation_phase_overrides: dict[str, object] | None = None,
) -> dict[str, object]:
    report = canonical_report()
    documentation_phase = valid_documentation_phase(metadata)
    documentation_phase.update(documentation_phase_overrides or {})
    return {
        "id": "sample-1",
        "completed_at": "2026-08-25T00:20:00Z",
        "error": None,
        "store": {
            "cybench.solution_phase": valid_solution_phase(),
            "cybench.documentation_phase": documentation_phase,
            "cybench.documentation_report": report,
            "cybench.documentation_work": valid_documentation_work(
                metadata,
                report,
            ),
        },
        "messages": canonical_messages(report),
        "events": [],
        "scores": {"includes": {"value": "C"}},
    }


def fake_log(
    metadata: dict[str, object],
    *,
    status: str = "success",
    documentation_phase_overrides: dict[str, object] | None = None,
) -> dict[str, object]:
    return {
        "status": status,
        "eval": {
            "task": "cybench_isolated",
            "task_id": "TASK123",
            "model": "MODEL123",
            "model_args": {
                "client_timeout": MODEL_API_CLIENT_TIMEOUT_SECONDS,
            },
            "metadata": metadata,
        },
        "samples": [
            valid_sample(
                metadata,
                documentation_phase_overrides=documentation_phase_overrides,
            )
        ],
        "results": {
            "total_samples": 1,
            "completed_samples": 1,
            "scores": [
                {
                    "name": "includes",
                    "scorer": "includes",
                    "scored_samples": 1,
                }
            ],
        },
    }


class CybenchRunHealthMetadataTests(unittest.TestCase):
    def run_health(
        self,
        metadata: dict[str, object],
        *,
        status: str = "success",
        require_complete: bool = False,
        expected_agent_policy: str | None = "baseline-v1",
        expected_agent_toolchain: str | None = "upstream-static-v1",
        expected_model_api_timeout_policy: str | None = (
            MODEL_API_TIMEOUT_POLICY
        ),
        expected_model_api_client_timeout_seconds: int | None = (
            MODEL_API_CLIENT_TIMEOUT_SECONDS
        ),
        expected_documentation_pipeline_id: str | None = (
            DOCUMENTATION_PIPELINE_ID
        ),
        expected_documentation_pipeline_version: int | None = (
            DOCUMENTATION_PIPELINE_VERSION
        ),
        expected_tool_output_max_bytes: int | None = 16_384,
        add_current_toolchain_metadata: bool = True,
        add_current_documentation_metadata: bool = True,
        documentation_phase_overrides: dict[str, object] | None = None,
        model_args_overrides: dict[str, object] | None = None,
        log_directory_name: str = "RUN123-cybench",
        sample_mutator: Callable[[dict[str, object]], None] | None = None,
    ) -> tuple[int, dict[str, object]]:
        metadata = dict(metadata)
        metadata.setdefault("orchestration_launch_id", "RUN123")
        if expected_model_api_timeout_policy is not None:
            metadata.setdefault(
                "model_api_timeout_policy",
                expected_model_api_timeout_policy,
            )
        if expected_model_api_client_timeout_seconds is not None:
            metadata.setdefault(
                "model_api_client_timeout_seconds",
                expected_model_api_client_timeout_seconds,
            )
        if (
            add_current_toolchain_metadata
            and expected_agent_toolchain == "upstream-static-v1"
        ):
            for key, value in current_toolchain_metadata().items():
                metadata.setdefault(key, value)
        if add_current_documentation_metadata:
            if expected_documentation_pipeline_id is not None:
                metadata.setdefault(
                    "documentation_pipeline_id",
                    expected_documentation_pipeline_id,
                )
            if expected_documentation_pipeline_version is not None:
                metadata.setdefault(
                    "documentation_pipeline_version",
                    expected_documentation_pipeline_version,
                )
        with tempfile.TemporaryDirectory() as temporary_directory:
            log_directory = Path(temporary_directory, log_directory_name)
            log_directory.mkdir()
            Path(log_directory, "run.eval").touch()
            argv = [
                "cybench_run_health.py",
                str(log_directory),
                "--expected-samples",
                "1",
                "--expected-model",
                "MODEL123",
                "--expected-task-id",
                "TASK123",
                "--expected-context-management",
                "summary_compaction",
                "--expected-compaction-threshold-tokens",
                "160000",
                "--expected-compaction-summary-max-tokens",
                "4096",
                "--expected-model-context-tokens",
                "262144",
            ]
            if expected_agent_policy is not None:
                argv.extend(["--expected-agent-policy", expected_agent_policy])
            if expected_agent_toolchain is not None:
                argv.extend(
                    ["--expected-agent-toolchain", expected_agent_toolchain]
                )
            if expected_model_api_timeout_policy is not None:
                argv.extend(
                    [
                        "--expected-model-api-timeout-policy",
                        expected_model_api_timeout_policy,
                    ]
                )
            if expected_model_api_client_timeout_seconds is not None:
                argv.extend(
                    [
                        "--expected-model-api-client-timeout-seconds",
                        str(expected_model_api_client_timeout_seconds),
                    ]
                )
            if expected_documentation_pipeline_id is not None:
                argv.extend(
                    [
                        "--expected-documentation-pipeline-id",
                        expected_documentation_pipeline_id,
                    ]
                )
            if expected_documentation_pipeline_version is not None:
                argv.extend(
                    [
                        "--expected-documentation-pipeline-version",
                        str(expected_documentation_pipeline_version),
                    ]
                )
            if expected_tool_output_max_bytes is not None:
                argv.extend(
                    [
                        "--expected-tool-output-max-bytes",
                        str(expected_tool_output_max_bytes),
                    ]
                )
            if require_complete:
                argv.append("--require-complete")
            log = fake_log(
                metadata,
                status=status,
                documentation_phase_overrides=(
                    documentation_phase_overrides
                ),
            )
            log["eval"]["model_args"].update(model_args_overrides or {})
            if sample_mutator is not None:
                sample_mutator(log["samples"][0])  # type: ignore[index]
            captured = io.StringIO()
            with (
                patch.object(sys, "argv", argv),
                patch.object(
                    cybench_run_health,
                    "read_eval_log",
                    return_value=log,
                ),
                redirect_stdout(captured),
            ):
                exit_code = cybench_run_health.main()
            return exit_code, json.loads(captured.getvalue())

    def test_current_compaction_metadata_is_accepted(self) -> None:
        exit_code, result = self.run_health(
            {
                "official_scorer": "includes",
                "agent_policy_version": "baseline-v1",
                "tool_output_max_bytes": 16_384,
                "context_management": "summary_compaction",
                "context_compaction_threshold_tokens": 160_000,
                "context_compaction_summary_max_tokens": 4_096,
                "context_compaction_summary_max_attempts": 2,
                "context_compaction_summary_completion": (
                    "best_nonempty_after_repair"
                ),
                "context_compaction_summary_retry_scope": (
                    "draft_only_when_available"
                ),
                "context_compaction_summary_priority": "next_steps_first",
                "context_compaction_summary_reasoning": "disabled",
                "model_context_tokens": 262_144,
            }
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual(result["state"], "complete")
        self.assertEqual(result["identity_errors"], [])
        self.assertEqual(
            result["actual_documentation_pipeline_id"],
            DOCUMENTATION_PIPELINE_ID,
        )
        self.assertEqual(
            result["actual_documentation_pipeline_version"],
            DOCUMENTATION_PIPELINE_VERSION,
        )

    def test_trace_diagnostics_validate_compaction_handoff_and_report(self) -> None:
        report = canonical_report()
        metadata = {
            "documentation_pipeline_id": DOCUMENTATION_PIPELINE_ID,
            "documentation_pipeline_version": DOCUMENTATION_PIPELINE_VERSION,
        }
        solution_phase = valid_solution_phase()
        solution_phase.update(
            {
                "message_count": 4,
                "non_system_message_count": 3,
                "message_ids": ["input", "summary", "continued"],
            }
        )
        documentation_phase = valid_documentation_phase(metadata)
        documentation_phase.update(
            {
                "input_message_count": 4,
                "input_context_source": "latest_compaction_window",
                "solution_message_count": 4,
                "history_messages_omitted": 1,
                "output_message_count": 2,
            }
        )
        diagnostics = cybench_run_health._sample_trace_diagnostics(
            {
                "id": "sample-1",
                "completed_at": "2026-08-25T00:20:00Z",
                "store": {
                    "cybench.solution_phase": solution_phase,
                    "cybench.documentation_phase": documentation_phase,
                    "cybench.documentation_report": report,
                    "cybench.documentation_work": valid_documentation_work(
                        metadata,
                        report,
                    ),
                },
                "messages": [
                    {"id": "solve-system", "role": "system", "content": "Policy"},
                    {"id": "input", "role": "user", "content": "Task"},
                    {
                        "id": "summary",
                        "role": "user",
                        "content": compaction_text(),
                        "metadata": compaction_metadata(),
                    },
                    {"id": "continued", "role": "assistant", "content": "Work"},
                    {"id": "doc-system", "role": "system", "content": "Doc policy"},
                    {
                        "id": "doc-handoff",
                        "role": "user",
                        "content": canonical_handoff(),
                    },
                    {"id": "doc-output", "role": "assistant", "content": report},
                ],
                "events": [
                    compaction_event(
                        uuid="compaction-1",
                        timestamp="2026-08-25T00:05:00Z",
                    )
                ],
            }
        )

        self.assertEqual(diagnostics["phase_errors"], [])
        self.assertEqual(diagnostics["trace_errors"], [])
        self.assertEqual(diagnostics["compaction_errors"], [])
        self.assertEqual(diagnostics["documentation_report_errors"], [])
        self.assertEqual(
            diagnostics["structural_handoffs"][0]["status"], "continued"
        )
        self.assertEqual(
            diagnostics["semantic_continuity"], "post_run_review_required"
        )

    def test_trace_diagnostics_reject_missing_trace_and_empty_report(self) -> None:
        diagnostics = cybench_run_health._sample_trace_diagnostics(
            {
                "id": "sample-1",
                "store": {
                    "cybench.solution_phase": {"message_ids": ["missing"]},
                    "cybench.documentation_report": "",
                },
                "messages": [],
                "events": [],
            }
        )

        self.assertTrue(diagnostics["trace_errors"])
        self.assertEqual(
            diagnostics["documentation_report_errors"],
            ["canonical documentation report is empty"],
        )

    def test_error_summary_never_persists_provider_request_text(self) -> None:
        secret = "SECRET_TRANSCRIPT_SENTINEL"
        summary = cybench_run_health.error_summary(
            {"type": "ModelGenerateError", "message": secret}
        )

        self.assertEqual(
            summary,
            {"type": "ModelGenerateError", "message_omitted": True},
        )
        self.assertNotIn(secret, json.dumps(summary))

    def test_trace_diagnostics_enforce_complete_solution_id_inventory(self) -> None:
        diagnostics = cybench_run_health._sample_trace_diagnostics(
            {
                "id": "sample-1",
                "store": {
                    "cybench.solution_phase": {
                        "message_ids": ["only-one"],
                        "non_system_message_count": 2,
                        "started_at_utc": "2026-08-25T00:00:00Z",
                        "completed_at_utc": "2026-08-25T00:10:00Z",
                    },
                    "cybench.documentation_report": "\n".join(
                        cybench_run_health.DOCUMENTATION_HEADINGS
                    ),
                },
                "messages": [{"id": "only-one", "role": "user"}],
                "events": [],
            }
        )

        self.assertIn(
            "solution phase message_ids count differs from non_system_message_count",
            diagnostics["trace_errors"],
        )

    def test_trace_diagnostics_ignore_documentation_phase_compaction(self) -> None:
        report = canonical_report()
        metadata = {
            "documentation_pipeline_id": DOCUMENTATION_PIPELINE_ID,
            "documentation_pipeline_version": DOCUMENTATION_PIPELINE_VERSION,
        }
        documentation_phase = valid_documentation_phase(metadata)
        documentation_phase.update(
            {
                "output_message_count": 3,
                "new_message_count": 3,
                "appended_message_count": 4,
            }
        )
        diagnostics = cybench_run_health._sample_trace_diagnostics(
            {
                "id": "sample-1",
                "completed_at": "2026-08-25T00:20:00Z",
                "store": {
                    "cybench.solution_phase": valid_solution_phase(),
                    "cybench.documentation_phase": documentation_phase,
                    "cybench.documentation_report": report,
                    "cybench.documentation_work": valid_documentation_work(
                        metadata,
                        report,
                    ),
                },
                "messages": [
                    {
                        "id": "solution-system",
                        "role": "system",
                        "content": "Solve policy",
                    },
                    {"id": "solution-input", "role": "user", "content": "Task"},
                    {
                        "id": "solution-output",
                        "role": "assistant",
                        "content": "Work",
                    },
                    {"id": "doc-system", "role": "system", "content": "Doc policy"},
                    {
                        "id": "doc-handoff",
                        "role": "user",
                        "content": canonical_handoff(),
                    },
                    {
                        "id": "doc-summary",
                        "role": "user",
                        "content": compaction_text(),
                        "metadata": compaction_metadata(),
                    },
                    {"id": "doc-output", "role": "assistant", "content": report},
                ],
                "events": [
                    compaction_event(
                        uuid="documentation-compaction-1",
                        timestamp="2026-08-25T00:15:00Z",
                    )
                ],
            }
        )

        self.assertEqual(diagnostics["phase_errors"], [])
        self.assertEqual(diagnostics["trace_errors"], [])
        self.assertEqual(diagnostics["compaction_count"], 0)
        self.assertEqual(diagnostics["summary_message_count"], 0)
        self.assertEqual(diagnostics["documentation_compaction_count"], 1)
        self.assertEqual(diagnostics["compaction_errors"], [])

    def test_phase_diagnostics_require_complete_consistent_chronology(self) -> None:
        metadata = {
            "documentation_pipeline_id": DOCUMENTATION_PIPELINE_ID,
            "documentation_pipeline_version": DOCUMENTATION_PIPELINE_VERSION,
        }

        sample = valid_sample(metadata)
        documentation_phase = sample["store"]["cybench.documentation_phase"]
        del documentation_phase["new_message_count"]
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertTrue(
            any(
                error.startswith(
                    "documentation phase is missing required fields:"
                )
                and "new_message_count" in error
                for error in diagnostics["phase_errors"]
            )
        )

        sample = valid_sample(metadata)
        solution_phase = sample["store"]["cybench.solution_phase"]
        solution_phase["started_at_utc"] = "2026-08-25T00:11:00Z"
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertIn(
            "solution phase time window is reversed",
            diagnostics["phase_errors"],
        )

        sample = valid_sample(metadata)
        documentation_phase = sample["store"]["cybench.documentation_phase"]
        documentation_phase["started_at_utc"] = "2026-08-25T00:09:00Z"
        documentation_phase["elapsed_seconds"] = 660.0
        documentation_phase["budget_fraction"] = 0.366667
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertIn(
            "documentation phase starts before solution phase completes",
            diagnostics["phase_errors"],
        )

        sample = valid_sample(metadata)
        documentation_phase = sample["store"]["cybench.documentation_phase"]
        documentation_phase["output_message_count"] = 99
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertIn(
            "documentation phase output message count is inconsistent",
            diagnostics["phase_errors"],
        )

    def test_solution_ids_bind_exactly_to_chronological_prefix(self) -> None:
        metadata = {
            "documentation_pipeline_id": DOCUMENTATION_PIPELINE_ID,
            "documentation_pipeline_version": DOCUMENTATION_PIPELINE_VERSION,
        }
        sample = valid_sample(metadata)
        solution_phase = sample["store"]["cybench.solution_phase"]
        solution_phase["message_ids"] = ["solution-output", "solution-input"]

        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)

        self.assertIn(
            "solution message_ids do not exactly match the chronological prefix",
            diagnostics["trace_errors"],
        )

        sample = valid_sample(metadata)
        sample["messages"][-1]["id"] = "solution-input"
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertIn(
            "solution message_ids do not occur exactly once in the sample",
            diagnostics["trace_errors"],
        )

    def test_documentation_handoff_and_report_are_exactly_bound(self) -> None:
        metadata = {
            "documentation_pipeline_id": DOCUMENTATION_PIPELINE_ID,
            "documentation_pipeline_version": DOCUMENTATION_PIPELINE_VERSION,
        }

        sample = valid_sample(metadata)
        sample["messages"][-1]["content"] = canonical_report() + "\nZusatz"
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertIn(
            "canonical documentation report is not bound to a suffix assistant message",
            diagnostics["trace_errors"],
        )
        self.assertIn(
            "canonical documentation report is not bound to the trace",
            diagnostics["documentation_report_errors"],
        )

        sample = valid_sample(metadata)
        sample["messages"][-2]["content"] = (
            cybench_run_health.DOCUMENTATION_HANDOFF_PREFIX
        )
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertIn(
            "documentation handoff content is inconsistent with the solution phase",
            diagnostics["trace_errors"],
        )

        sample = valid_sample(metadata)
        sample["messages"].insert(
            -1,
            {
                "id": "duplicate-handoff",
                "role": "user",
                "content": canonical_handoff(),
            },
        )
        sample["store"]["cybench.documentation_phase"].update(
            {
                "output_message_count": 3,
                "new_message_count": 3,
                "appended_message_count": 4,
            }
        )
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertIn(
            "documentation suffix must contain exactly one canonical handoff",
            diagnostics["trace_errors"],
        )

    def test_summary_content_and_event_identity_are_validated(self) -> None:
        summary = {
            "id": "summary-1",
            "role": "user",
            "content": compaction_text(),
            "metadata": compaction_metadata(),
        }
        sample = compacted_solution_sample(
            [
                {"id": "input", "role": "user", "content": "Task"},
                summary,
                {"id": "continued", "role": "assistant", "content": "Work"},
            ],
            [
                compaction_event(
                    uuid="compaction-1",
                    timestamp="2026-08-25T00:05:00Z",
                )
            ],
        )
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertEqual(diagnostics["compaction_errors"], [])

        sample["events"][0]["timestamp"] = "2026-08-25T00:15:00Z"
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertIn(
            "solution compaction event lies outside its phase window",
            diagnostics["compaction_errors"],
        )
        sample["events"][0]["timestamp"] = "2026-08-25T00:05:00Z"

        summary["content"] = compaction_text().replace(
            cybench_run_health.COMPACTION_PREFIX,
            cybench_run_health.COMPACTION_PREFIX + "-ungueltig",
            1,
        )
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertIn(
            "summary 1 is missing the compaction prefix",
            diagnostics["compaction_errors"],
        )

        summary["content"] = (
            f"{cybench_run_health.COMPACTION_PREFIX}\n"
            + " / ".join(cybench_run_health.COMPACTION_REQUIRED_SECTIONS)
            + f"\n{cybench_run_health.COMPACTION_CONTINUATION}"
        )
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertTrue(
            any(
                "invalid summary wrapper cardinality" in error
                for error in diagnostics["compaction_errors"]
            )
        )

        summary["content"] = compaction_text(
            cybench_run_health.COMPACTION_REQUIRED_SECTIONS[:1]
        )
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertIn(
            "summary 1 section metadata differs from its content",
            diagnostics["compaction_errors"],
        )
        self.assertIn(
            "summary 1 claims completeness without all continuation sections",
            diagnostics["compaction_errors"],
        )

        first_summary = {
            "id": "summary-a",
            "role": "user",
            "content": compaction_text(),
            "metadata": compaction_metadata(),
        }
        second_summary = {
            "id": "summary-b",
            "role": "user",
            "content": compaction_text(),
            "metadata": compaction_metadata(),
        }
        sample = compacted_solution_sample(
            [
                {"id": "input", "role": "user", "content": "Task"},
                first_summary,
                {"id": "action", "role": "assistant", "content": "Work"},
                second_summary,
                {"id": "continued", "role": "assistant", "content": "More"},
            ],
            [
                compaction_event(
                    uuid="same-event",
                    timestamp="2026-08-25T00:04:00Z",
                ),
                compaction_event(
                    uuid="same-event",
                    timestamp="2026-08-25T00:06:00Z",
                ),
            ],
        )
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertIn(
            "compaction event uuids contain duplicates",
            diagnostics["compaction_errors"],
        )

    def test_summary_to_summary_is_not_counted_as_continuation(self) -> None:
        sample = compacted_solution_sample(
            [
                {"id": "input", "role": "user", "content": "Task"},
                {
                    "id": "summary-a",
                    "role": "user",
                    "content": compaction_text(),
                    "metadata": compaction_metadata(),
                },
                {
                    "id": "summary-b",
                    "role": "user",
                    "content": compaction_text(),
                    "metadata": compaction_metadata(),
                },
                {"id": "continued", "role": "assistant", "content": "Work"},
            ],
            [
                compaction_event(
                    uuid="event-a",
                    timestamp="2026-08-25T00:04:00Z",
                ),
                compaction_event(
                    uuid="event-b",
                    timestamp="2026-08-25T00:06:00Z",
                ),
            ],
        )

        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)

        self.assertIn(
            "a solution summary was followed by another compaction "
            "without agent action",
            diagnostics["compaction_errors"],
        )
        self.assertEqual(
            diagnostics["structural_handoffs"][0]["status"],
            "recompacted_without_agent_action",
        )

        metadata = {
            "documentation_pipeline_id": DOCUMENTATION_PIPELINE_ID,
            "documentation_pipeline_version": DOCUMENTATION_PIPELINE_VERSION,
        }
        sample = valid_sample(metadata)
        report = canonical_report()
        documentation_summaries = [
            {
                "id": f"doc-summary-{index}",
                "role": "user",
                "content": compaction_text(),
                "metadata": compaction_metadata(),
            }
            for index in (1, 2)
        ]
        sample["messages"] = [
            *sample["messages"][:-1],
            *documentation_summaries,
            {"id": "documentation-output", "role": "assistant", "content": report},
        ]
        sample["events"] = [
            compaction_event(
                uuid="doc-event-a",
                timestamp="2026-08-25T00:14:00Z",
            ),
            compaction_event(
                uuid="doc-event-b",
                timestamp="2026-08-25T00:16:00Z",
            ),
        ]
        sample["store"]["cybench.documentation_phase"].update(
            {
                "output_message_count": 4,
                "new_message_count": 4,
                "appended_message_count": 5,
            }
        )
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertIn(
            "a documentation summary was followed by another compaction "
            "without agent action",
            diagnostics["compaction_errors"],
        )
        self.assertEqual(
            diagnostics["documentation_structural_handoffs"][0]["status"],
            "recompacted_without_agent_action",
        )

    def test_documentation_requires_real_markdown_headings_and_nonempty_bodies(
        self,
    ) -> None:
        metadata = {
            "documentation_pipeline_id": DOCUMENTATION_PIPELINE_ID,
            "documentation_pipeline_version": DOCUMENTATION_PIPELINE_VERSION,
        }
        for report in (
            "\n".join(
                f"{heading}\nInhalt"
                for heading in cybench_run_health.DOCUMENTATION_HEADINGS
            ),
            "\n".join(
                f"**{heading}**\nInhalt"
                for heading in cybench_run_health.DOCUMENTATION_HEADINGS
            ),
            "```markdown\n"
            + canonical_report()
            + "\n```",
        ):
            with self.subTest(report=report[:20]):
                sample = valid_sample(metadata)
                sample["store"]["cybench.documentation_report"] = report
                sample["messages"][-1]["content"] = report
                diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
                self.assertIn(
                    "canonical documentation report is missing required headings",
                    diagnostics["documentation_report_errors"],
                )

        empty_body_report = "\n".join(
            f"## {heading}\n"
            + ("" if index == 2 else "Inhalt")
            for index, heading in enumerate(
                cybench_run_health.DOCUMENTATION_HEADINGS
            )
        )
        sample = valid_sample(metadata)
        sample["store"]["cybench.documentation_report"] = empty_body_report
        sample["messages"][-1]["content"] = empty_body_report
        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)
        self.assertIn(
            "canonical documentation report has an empty required section",
            diagnostics["documentation_report_errors"],
        )

    def test_limit_reached_with_a_complete_bound_report_remains_valid(self) -> None:
        def mark_documentation_limit(sample: dict[str, object]) -> None:
            documentation_phase = sample["store"]["cybench.documentation_phase"]
            documentation_phase.update(
                {
                    "status": "limit_reached",
                    "limit_type": "time",
                    "limit_message": "time limit reached",
                    "elapsed_seconds": 1_800.0,
                    "budget_fraction": 1.0,
                    "completed_at_utc": "2026-08-25T00:40:00Z",
                }
            )
            sample["completed_at"] = "2026-08-25T00:40:00Z"

        exit_code, result = self.run_health(
            run_contract_metadata(),
            sample_mutator=mark_documentation_limit,
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual(result["state"], "complete")
        self.assertEqual(result["phase_error_samples"], [])

    def test_valid_incorrect_score_is_not_a_technical_failure(self) -> None:
        def mark_incorrect(sample: dict[str, object]) -> None:
            sample["scores"]["includes"]["value"] = "I"

        exit_code, result = self.run_health(
            run_contract_metadata(),
            sample_mutator=mark_incorrect,
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual(result["state"], "complete")
        self.assertEqual(result["invalid_official_scores"], [])

    def test_orchestration_launch_id_is_strict_and_bound_to_directory(self) -> None:
        invalid_metadata = run_contract_metadata()
        invalid_metadata["orchestration_launch_id"] = "RUN_123"
        exit_code, result = self.run_health(invalid_metadata)
        self.assertEqual(exit_code, 2)
        self.assertIn(
            "orchestration launch id metadata is invalid",
            result["identity_errors"],
        )

        mismatched_metadata = run_contract_metadata()
        mismatched_metadata["orchestration_launch_id"] = "OTHER"
        exit_code, result = self.run_health(mismatched_metadata)
        self.assertEqual(exit_code, 2)
        self.assertIn(
            "orchestration launch id does not match the log directory",
            result["identity_errors"],
        )

    def test_documentation_pipeline_run_metadata_is_enforced(self) -> None:
        exit_code, result = self.run_health(
            {
                "official_scorer": "includes",
                "agent_policy_version": "baseline-v1",
                "tool_output_max_bytes": 16_384,
                "context_management": "summary_compaction",
                "context_compaction_threshold_tokens": 160_000,
                "context_compaction_summary_max_tokens": 4_096,
                "context_compaction_summary_max_attempts": 2,
                "context_compaction_summary_completion": (
                    "best_nonempty_after_repair"
                ),
                "context_compaction_summary_retry_scope": (
                    "draft_only_when_available"
                ),
                "context_compaction_summary_priority": "next_steps_first",
                "context_compaction_summary_reasoning": "disabled",
                "model_context_tokens": 262_144,
            },
            add_current_documentation_metadata=False,
        )

        self.assertEqual(exit_code, 2)
        self.assertIn(
            "documentation pipeline id metadata mismatch",
            result["identity_errors"],
        )
        self.assertIn(
            "documentation pipeline version metadata mismatch",
            result["identity_errors"],
        )

    def test_documentation_pipeline_sample_store_is_enforced(self) -> None:
        exit_code, result = self.run_health(
            {
                "official_scorer": "includes",
                "agent_policy_version": "baseline-v1",
                "tool_output_max_bytes": 16_384,
                "context_management": "summary_compaction",
                "context_compaction_threshold_tokens": 160_000,
                "context_compaction_summary_max_tokens": 4_096,
                "context_compaction_summary_max_attempts": 2,
                "context_compaction_summary_completion": (
                    "best_nonempty_after_repair"
                ),
                "context_compaction_summary_retry_scope": (
                    "draft_only_when_available"
                ),
                "context_compaction_summary_priority": "next_steps_first",
                "context_compaction_summary_reasoning": "disabled",
                "model_context_tokens": 262_144,
            },
            documentation_phase_overrides={
                "documentation_pipeline_version": 1,
            },
        )

        self.assertEqual(exit_code, 2)
        self.assertEqual(result["identity_errors"], [])
        self.assertEqual(
            result["documentation_pipeline_mismatch_samples"],
            [
                {
                    "sample_id": "sample-1",
                    "field": "documentation_pipeline_version",
                    "actual": 1,
                }
            ],
        )

    def test_previous_strict_2048_policy_is_rejected(self) -> None:
        exit_code, result = self.run_health(
            {
                "official_scorer": "includes",
                "agent_policy_version": "baseline-v1",
                "tool_output_max_bytes": 16_384,
                "context_management": "summary_compaction",
                "context_compaction_threshold_tokens": 160_000,
                "context_compaction_summary_max_tokens": 2_048,
                "context_compaction_summary_completion": "required",
                "context_compaction_summary_retry_scope": "draft_only",
                "context_compaction_summary_reasoning": "disabled",
                "model_context_tokens": 262_144,
            }
        )

        self.assertEqual(exit_code, 2)
        self.assertEqual(result["state"], "technical_error")
        self.assertIn(
            "context compaction summary max metadata mismatch",
            result["identity_errors"],
        )
        self.assertIn(
            "context compaction completion metadata mismatch",
            result["identity_errors"],
        )

    def test_agent_policy_and_tool_output_contract_are_enforced(self) -> None:
        exit_code, result = self.run_health(
            {
                "official_scorer": "includes",
                "agent_policy_version": "efficient-v2",
                "tool_output_max_bytes": 8_192,
                "context_management": "summary_compaction",
                "context_compaction_threshold_tokens": 160_000,
                "context_compaction_summary_max_tokens": 4_096,
                "context_compaction_summary_max_attempts": 2,
                "context_compaction_summary_completion": (
                    "best_nonempty_after_repair"
                ),
                "context_compaction_summary_retry_scope": (
                    "draft_only_when_available"
                ),
                "context_compaction_summary_priority": "next_steps_first",
                "context_compaction_summary_reasoning": "disabled",
                "model_context_tokens": 262_144,
            }
        )

        self.assertEqual(exit_code, 2)
        self.assertIn("agent policy metadata mismatch", result["identity_errors"])
        self.assertIn(
            "tool output maximum metadata mismatch",
            result["identity_errors"],
        )

    def test_model_api_timeout_contract_binds_metadata_and_provider_argument(
        self,
    ) -> None:
        metadata = run_contract_metadata()
        metadata["model_api_timeout_policy"] = "legacy-sdk-default"
        metadata["model_api_client_timeout_seconds"] = 600

        exit_code, result = self.run_health(metadata)

        self.assertEqual(exit_code, 2)
        self.assertIn(
            "model API timeout policy metadata mismatch",
            result["identity_errors"],
        )
        self.assertIn(
            "model API client timeout metadata mismatch",
            result["identity_errors"],
        )

        metadata = run_contract_metadata()
        exit_code, result = self.run_health(
            metadata,
            model_args_overrides={"client_timeout": 600},
        )

        self.assertEqual(exit_code, 2)
        self.assertIn(
            "model API client timeout model argument mismatch",
            result["identity_errors"],
        )

    def test_neutral_policy_requires_its_exact_prompt_hash(self) -> None:
        metadata = run_contract_metadata()
        metadata["agent_policy_version"] = AGENT_POLICY_NEUTRAL
        metadata["agent_prompt_sha256"] = agent_policy_prompt_sha256(
            AGENT_POLICY_NEUTRAL
        )

        exit_code, result = self.run_health(
            metadata,
            expected_agent_policy=AGENT_POLICY_NEUTRAL,
        )
        self.assertEqual(exit_code, 0)
        self.assertEqual(result["identity_errors"], [])

        metadata["agent_prompt_sha256"] = "0" * 64
        exit_code, result = self.run_health(
            metadata,
            expected_agent_policy=AGENT_POLICY_NEUTRAL,
        )
        self.assertEqual(exit_code, 2)
        self.assertIn(
            "agent prompt SHA-256 metadata mismatch",
            result["identity_errors"],
        )

    def test_legacy_unversioned_policy_can_be_bound_explicitly(self) -> None:
        exit_code, result = self.run_health(
            {
                "official_scorer": "includes",
                "context_management": "summary_compaction",
                "context_compaction_threshold_tokens": 160_000,
                "context_compaction_summary_max_tokens": 4_096,
                "context_compaction_summary_max_attempts": 2,
                "context_compaction_summary_completion": (
                    "best_nonempty_after_repair"
                ),
                "context_compaction_summary_retry_scope": (
                    "draft_only_when_available"
                ),
                "context_compaction_summary_priority": "next_steps_first",
                "context_compaction_summary_reasoning": "disabled",
                "model_context_tokens": 262_144,
            },
            expected_agent_policy="legacy-unversioned",
            expected_agent_toolchain="legacy-unversioned",
            expected_tool_output_max_bytes=None,
            add_current_toolchain_metadata=False,
        )

        self.assertEqual(exit_code, 0)
        self.assertEqual(result["identity_errors"], [])

    def test_agent_toolchain_contract_is_enforced(self) -> None:
        metadata = {
            "official_scorer": "includes",
            "agent_policy_version": "baseline-v1",
            "tool_output_max_bytes": 16_384,
            "context_management": "summary_compaction",
            "context_compaction_threshold_tokens": 160_000,
            "context_compaction_summary_max_tokens": 4_096,
            "context_compaction_summary_max_attempts": 2,
            "context_compaction_summary_completion": "best_nonempty_after_repair",
            "context_compaction_summary_retry_scope": "draft_only_when_available",
            "context_compaction_summary_priority": "next_steps_first",
            "context_compaction_summary_reasoning": "disabled",
            "model_context_tokens": 262_144,
            **current_toolchain_metadata(),
        }
        metadata["agent_toolchain_image_digest"] = "sha256:" + "0" * 64

        exit_code, result = self.run_health(
            metadata,
            add_current_toolchain_metadata=False,
        )

        self.assertEqual(exit_code, 2)
        self.assertIn(
            "agent toolchain image digest metadata mismatch",
            result["identity_errors"],
        )

    def test_require_complete_rejects_running_log(self) -> None:
        metadata = {
            "official_scorer": "includes",
            "agent_policy_version": "baseline-v1",
            "tool_output_max_bytes": 16_384,
            "context_management": "summary_compaction",
            "context_compaction_threshold_tokens": 160_000,
            "context_compaction_summary_max_tokens": 4_096,
            "context_compaction_summary_max_attempts": 2,
            "context_compaction_summary_completion": (
                "best_nonempty_after_repair"
            ),
            "context_compaction_summary_retry_scope": (
                "draft_only_when_available"
            ),
            "context_compaction_summary_priority": "next_steps_first",
            "context_compaction_summary_reasoning": "disabled",
            "model_context_tokens": 262_144,
        }

        exit_code, result = self.run_health(
            metadata,
            status="running",
            require_complete=True,
        )

        self.assertEqual(result["state"], "running")
        self.assertEqual(exit_code, 2)

    def test_iterative_documentation_lineage_is_hash_and_attempt_bound(self) -> None:
        metadata = {
            "documentation_pipeline_id": DOCUMENTATION_PIPELINE_ID,
            "documentation_pipeline_version": DOCUMENTATION_PIPELINE_VERSION,
        }
        sample = valid_sample(metadata)
        work = sample["store"]["cybench.documentation_work"]
        final_stage = work["stages"]["final_synthesis"]
        final_stage["accepted_report_sha256"] = "0" * 64
        final_stage["attempts"] = 2

        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)

        self.assertIn(
            "iterative documentation report lineage hash is inconsistent",
            diagnostics["phase_errors"],
        )
        self.assertIn(
            "iterative documentation stage call count is inconsistent",
            diagnostics["phase_errors"],
        )
        self.assertNotIn(canonical_report(), str(diagnostics["phase_errors"]))

    def test_historical_v2_output_count_contract_remains_unchanged(self) -> None:
        metadata = {
            "documentation_pipeline_id": "react-active-window",
            "documentation_pipeline_version": 2,
        }
        sample = valid_sample(metadata)
        documentation_phase = sample["store"]["cybench.documentation_phase"]
        documentation_phase.update(
            {
                "input_message_count": 3,
                "output_message_count": 5,
            }
        )

        diagnostics = cybench_run_health._sample_trace_diagnostics(sample)

        self.assertNotIn(
            "documentation phase output message count is inconsistent",
            diagnostics["phase_errors"],
        )
        self.assertNotIn(
            "iterative documentation work state is missing",
            diagnostics["phase_errors"],
        )


if __name__ == "__main__":
    unittest.main()

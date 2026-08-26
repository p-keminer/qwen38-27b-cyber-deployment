from __future__ import annotations

import asyncio
import inspect
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from inspect_ai.model import (
    ChatMessageAssistant,
    ChatMessageSystem,
    ChatMessageUser,
)
from inspect_ai.tool import ToolCall

from evals.cybench import (
    COMPACTION_END_MARKER,
    COMPACTION_MAX_ATTEMPTS,
    COMPACTION_MAX_OUTPUT_TOKENS,
    COMPACTION_REQUIRED_SECTIONS,
    COMPACTION_TARGET_OUTPUT_TOKENS,
    COMPACTION_THRESHOLD_TOKENS,
    DOCUMENTATION_DERIVED_MAX_INPUT_TOKENS,
    DOCUMENTATION_DRAFTS_END_MARKER,
    DOCUMENTATION_EVIDENCE_MAX_INPUT_TOKENS,
    DOCUMENTATION_EVIDENCE_END_MARKER,
    DOCUMENTATION_FINAL_END_MARKER,
    DOCUMENTATION_MAX_OUTPUT_TOKENS,
    DOCUMENTATION_PIPELINE_ID,
    DOCUMENTATION_PIPELINE_VERSION,
    DOCUMENTATION_REQUIRED_HEADINGS,
    DocumentationStageError,
    GERMAN_COMPACTION_PROMPT,
    GermanCompactionSummary,
    MAX_MODEL_CONTEXT_TOKENS,
    classified_documentation_error,
    documentation_context,
    documentation_drafts_input,
    documentation_evidence_input,
    documentation_final_input,
    documentation_generation_config,
    documentation_generated_messages,
    documentation_trace_messages,
    generate_documentation_stage,
    generate_documentation_submission,
    solve_then_document,
    validate_documentation_report,
)


async def identity_fit(_model: object, messages: list[object]) -> list[object]:
    return messages


def candidate(*, marker: bool = True, suffix: str = "") -> str:
    parts = [
        f"## {section}\nBelegter Inhalt zu diesem Abschnitt."
        for section in COMPACTION_REQUIRED_SECTIONS
    ]
    if suffix:
        parts.append(suffix)
    if marker:
        parts.append(COMPACTION_END_MARKER)
    return "\n\n".join(parts)


class FakeModel:
    def __init__(self, *outputs: object) -> None:
        self.outputs = list(outputs)
        self.calls: list[dict[str, object]] = []
        self.config = SimpleNamespace(max_tokens=None)

    async def generate(self, **kwargs: object) -> object:
        self.calls.append(kwargs)
        output = self.outputs.pop(0)
        if isinstance(output, BaseException):
            raise output
        return output


def output(completion: str, stop_reason: str) -> SimpleNamespace:
    return SimpleNamespace(completion=completion, stop_reason=stop_reason)


def documentation_report(body: str = "Belegter Inhalt.") -> str:
    return "\n\n".join(
        f"## {heading}\n{body}" for heading in DOCUMENTATION_REQUIRED_HEADINGS
    )


class FakeDocumentationModel:
    def __init__(
        self,
        completion: str,
        *,
        stop_reason: str = "stop",
        input_tokens: int = 100,
    ) -> None:
        self.output = output(completion, stop_reason)
        self.input_token_count = input_tokens
        self.calls: list[dict[str, object]] = []
        self.count_calls: list[tuple[object, object]] = []

    async def count_tokens(self, messages: object, config: object = None) -> int:
        self.count_calls.append((messages, config))
        return self.input_token_count

    async def generate(self, **kwargs: object) -> object:
        self.calls.append(kwargs)
        return self.output


class GermanCompactionSummaryTests(unittest.IsolatedAsyncioTestCase):
    def strategy(self) -> GermanCompactionSummary:
        return GermanCompactionSummary(
            threshold=COMPACTION_THRESHOLD_TOKENS,
            memory=False,
            prompt=GERMAN_COMPACTION_PROMPT,
        )

    def messages(self) -> list[object]:
        return [
            ChatMessageSystem(content="Systemvorgabe"),
            ChatMessageUser(content="Aufgabe"),
            ChatMessageUser(content="OLD_HISTORY_SENTINEL"),
        ]

    async def compact(
        self,
        model: FakeModel,
        tools: list[object] | None = None,
    ) -> tuple[list[object], object]:
        with patch("evals.cybench._fit_summarization_input", new=identity_fit):
            compacted, summary = await self.strategy().compact(
                model,  # type: ignore[arg-type]
                self.messages(),  # type: ignore[arg-type]
                tools or [],  # type: ignore[arg-type]
            )
        assert summary is not None
        return compacted, summary

    def test_constants_and_priority_order(self) -> None:
        self.assertEqual(COMPACTION_THRESHOLD_TOKENS, 160_000)
        self.assertEqual(COMPACTION_TARGET_OUTPUT_TOKENS, 1_200)
        self.assertEqual(COMPACTION_MAX_OUTPUT_TOKENS, 4_096)
        self.assertEqual(COMPACTION_MAX_ATTEMPTS, 2)
        positions = [
            GERMAN_COMPACTION_PROMPT.index(section)
            for section in COMPACTION_REQUIRED_SECTIONS
        ]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(COMPACTION_REQUIRED_SECTIONS[0], "Nächste Schritte")
        self.assertEqual(
            COMPACTION_REQUIRED_SECTIONS[1],
            "Letzter belastbarer Stand",
        )

    async def test_complete_first_attempt_uses_tools_and_stops(self) -> None:
        model = FakeModel(output(candidate(), "stop"))
        tools = [object()]

        compacted, summary = await self.compact(model, tools)

        self.assertEqual(len(model.calls), 1)
        self.assertIs(model.calls[0]["tools"], tools)
        self.assertEqual(model.calls[0]["tool_choice"], "none")
        config = model.calls[0]["config"]
        self.assertEqual(config.max_tokens, 4_096)
        self.assertEqual(config.reasoning_effort, "none")
        self.assertEqual(
            config.extra_body,
            {"chat_template_kwargs": {"enable_thinking": False}},
        )
        self.assertIsNone(model.config.max_tokens)
        self.assertNotIn(COMPACTION_END_MARKER, str(summary.content))
        self.assertTrue(summary.metadata["summary_complete"])
        self.assertFalse(summary.metadata["summary_forced_accept"])
        self.assertEqual(summary.metadata["summary_source"], "full_history")
        self.assertEqual(summary.metadata["summary_generation_attempts"], 1)
        self.assertIs(compacted[-1], summary)

    async def test_second_attempt_repairs_only_draft_and_is_accepted(self) -> None:
        first = candidate(marker=False)
        second = candidate(marker=False, suffix="Reparierter Entwurf")
        model = FakeModel(
            output(first, "max_tokens"),
            output(second, "max_tokens"),
        )
        tools = [object()]

        _, summary = await self.compact(model, tools)

        self.assertEqual(len(model.calls), 2)
        first_text = "\n".join(
            str(message.content) for message in model.calls[0]["input"]
        )
        second_text = "\n".join(
            str(message.content) for message in model.calls[1]["input"]
        )
        self.assertIn("OLD_HISTORY_SENTINEL", first_text)
        self.assertNotIn("OLD_HISTORY_SENTINEL", second_text)
        self.assertIn(first, second_text)
        for section in COMPACTION_REQUIRED_SECTIONS:
            self.assertIn(section, second_text)
        self.assertEqual(model.calls[1]["tools"], [])
        self.assertIsNone(model.calls[1]["tool_choice"])
        self.assertEqual(model.calls[1]["config"].max_tokens, 4_096)
        self.assertEqual(summary.metadata["summary_source"], "draft_repair")
        self.assertTrue(summary.metadata["summary_forced_accept"])
        self.assertEqual(summary.metadata["summary_generation_attempts"], 2)
        self.assertNotIn(COMPACTION_END_MARKER, str(summary.content))

    async def test_worse_repair_does_not_replace_richer_first_draft(self) -> None:
        first = candidate(marker=False)
        second = "## Nächste Schritte\nNur ein Abschnitt."
        model = FakeModel(
            output(first, "max_tokens"),
            output(second, "max_tokens"),
        )

        _, summary = await self.compact(model)

        self.assertEqual(summary.metadata["summary_source"], "full_history")
        self.assertIn("Bestätigte Fakten", str(summary.content))
        self.assertEqual(summary.metadata["summary_generation_attempts"], 2)

    async def test_empty_or_failed_repair_falls_back_to_first_draft(self) -> None:
        for repair in (
            output("   ", "stop"),
            RuntimeError("repair failed"),
        ):
            with self.subTest(repair=type(repair).__name__):
                model = FakeModel(
                    output(candidate(marker=False), "max_tokens"),
                    repair,
                )
                _, summary = await self.compact(model)
                self.assertEqual(
                    summary.metadata["summary_source"],
                    "full_history",
                )
                self.assertEqual(
                    summary.metadata["summary_generation_attempts"],
                    2,
                )
                if isinstance(repair, RuntimeError):
                    self.assertEqual(
                        summary.metadata["summary_repair_error_type"],
                        "RuntimeError",
                    )

    async def test_two_empty_attempts_raise(self) -> None:
        model = FakeModel(
            output(COMPACTION_END_MARKER, "max_tokens"),
            output("   ", "stop"),
        )

        with self.assertRaisesRegex(RuntimeError, "non-empty"):
            await self.compact(model)
        self.assertEqual(len(model.calls), 2)
        self.assertIn(
            "OLD_HISTORY_SENTINEL",
            "\n".join(
                str(message.content) for message in model.calls[1]["input"]
            ),
        )

    async def test_repair_cancellation_propagates(self) -> None:
        model = FakeModel(
            output(candidate(marker=False), "max_tokens"),
            asyncio.CancelledError(),
        )

        with self.assertRaises(asyncio.CancelledError):
            await self.compact(model)

    async def test_filtered_or_model_length_text_is_not_accepted(self) -> None:
        for stop_reason in ("content_filter", "model_length"):
            with self.subTest(stop_reason=stop_reason):
                model = FakeModel(
                    output(candidate(marker=False), stop_reason),
                    output("", "stop"),
                )
                with self.assertRaisesRegex(RuntimeError, "non-empty"):
                    await self.compact(model)

    def test_reasoning_only_headings_do_not_count_as_complete(self) -> None:
        hidden = candidate(marker=False)
        raw = (
            f"<think>{hidden}</think>\n"
            "Kurze sichtbare Notiz.\n"
            f"{COMPACTION_END_MARKER}"
        )
        self.assertFalse(
            GermanCompactionSummary._is_complete(raw, "stop")
        )


class DocumentationContextTests(unittest.TestCase):
    def test_documentation_error_never_serializes_provider_message(self) -> None:
        secret = "CYBENCH{must-not-enter-phase-metadata}"

        result = classified_documentation_error(
            RuntimeError(f"provider request contained {secret}")
        )

        self.assertEqual(result["classification"], "documentation_agent")
        self.assertEqual(result["exception_type"], "RuntimeError")
        self.assertTrue(result["provider_message_omitted"])
        self.assertNotIn(secret, str(result))

    def test_model_generation_error_is_classified_without_its_text(self) -> None:
        ModelGenerateError = type("ModelGenerateError", (RuntimeError,), {})
        secret = "reasoning_content=PRIVATE_SENTINEL"

        result = classified_documentation_error(ModelGenerateError(secret))

        self.assertEqual(result["classification"], "model_generation")
        self.assertEqual(result["exception_type"], "ModelGenerateError")
        self.assertNotIn(secret, str(result))

    def test_latest_compaction_window_excludes_superseded_history(self) -> None:
        task = ChatMessageUser(content="Aufgabe")
        reminder = ChatMessageUser(content="Randbedingungen")
        old_work = ChatMessageAssistant(content="OLD_HISTORY_SENTINEL")
        old_summary = ChatMessageUser(
            content="Alte Zusammenfassung",
            metadata={"summary": True},
        )
        later_work = ChatMessageAssistant(content="Neuer Zwischenstand")
        latest_summary = ChatMessageUser(
            content="Aktueller belastbarer Stand",
            metadata={"summary": True},
        )
        final_work = ChatMessageAssistant(content="Letzter Fortschritt")

        context, source = documentation_context(
            [
                ChatMessageSystem(content="Solve-System"),
                task,
                reminder,
                old_work,
                old_summary,
                later_work,
                latest_summary,
                final_work,
            ]
        )

        self.assertEqual(source, "latest_compaction_window")
        self.assertEqual(context, [latest_summary, final_work])
        self.assertNotIn("OLD_HISTORY_SENTINEL", str(context))
        self.assertNotIn(task, context)
        self.assertNotIn(reminder, context)

    def test_full_transcript_is_used_when_no_summary_exists(self) -> None:
        task = ChatMessageUser(content="Aufgabe")
        work = ChatMessageAssistant(content="Arbeit")

        context, source = documentation_context(
            [ChatMessageSystem(content="Solve-System"), task, work]
        )

        self.assertEqual(source, "full_solution_transcript")
        self.assertEqual(context, [task, work])

    def test_generated_messages_exclude_copied_documentation_input(self) -> None:
        copied_task = ChatMessageUser(content="Aufgabe", source="input")
        copied_summary = ChatMessageUser(
            content="Aktueller Stand",
            metadata={"summary": True},
            source="input",
        )
        documentation_system = ChatMessageSystem(content="Dokumentationsvorgabe")
        documentation_report = ChatMessageAssistant(content="Bericht")

        generated = documentation_generated_messages(
            [
                copied_task,
                copied_summary,
                documentation_system,
                documentation_report,
            ]
        )

        self.assertEqual(
            generated,
            [documentation_system, documentation_report],
        )

    def test_trace_preserves_unique_handoff_in_chronological_order(self) -> None:
        copied_context = ChatMessageUser(content="Aktueller Stand", source="input")
        copied_handoff = ChatMessageUser(content="Bericht anfertigen", source="input")
        handoff = ChatMessageUser(content="Bericht anfertigen", id="doc-handoff")
        documentation_system = ChatMessageSystem(
            content="Dokumentationsvorgabe",
            id="doc-system",
        )
        documentation_report = ChatMessageAssistant(
            content="Bericht",
            id="doc-report",
        )

        trace_messages = documentation_trace_messages(
            [
                documentation_system,
                copied_context,
                copied_handoff,
                documentation_report,
            ],
            handoff,
        )

        self.assertEqual(
            [message.id for message in trace_messages],
            ["doc-system", "doc-handoff", "doc-report"],
        )

    def test_full_solution_trace_is_preserved_without_context_duplicates(self) -> None:
        solution_messages = [
            ChatMessageSystem(content="Solve-System", id="solve-system"),
            ChatMessageUser(content="Aufgabe", id="solve-task"),
            ChatMessageAssistant(content="Alte Arbeit", id="solve-old"),
            ChatMessageUser(
                content="Aktueller Stand",
                metadata={"summary": True},
                id="solve-summary",
            ),
            ChatMessageAssistant(content="Neue Arbeit", id="solve-new"),
        ]
        report_context, _ = documentation_context(solution_messages)
        copied_report_input = [
            message.model_copy(update={"source": "input"})
            for message in report_context
        ]
        documentation_system = ChatMessageSystem(
            content="Dokumentationsvorgabe",
            id="doc-system",
        )
        documentation_report = ChatMessageAssistant(
            content="Bericht",
            id="doc-report",
        )

        handoff = ChatMessageUser(content="Bericht anfertigen", id="doc-handoff")
        trace_messages = documentation_trace_messages(
            [
                *copied_report_input,
                documentation_system,
                handoff.model_copy(update={"source": "input"}),
                documentation_report,
            ],
            handoff,
        )
        canonical_messages = [*solution_messages, *trace_messages]

        self.assertEqual(
            [message.id for message in canonical_messages],
            [
                "solve-system",
                "solve-task",
                "solve-old",
                "solve-summary",
                "solve-new",
                "doc-system",
                "doc-handoff",
                "doc-report",
            ],
        )
        self.assertEqual(
            sum(message.id == "solve-summary" for message in canonical_messages),
            1,
        )


class IterativeDocumentationPipelineTests(unittest.IsolatedAsyncioTestCase):
    def test_pipeline_contract_and_deterministic_generation_config(self) -> None:
        self.assertEqual(DOCUMENTATION_PIPELINE_ID, "iterative-active-window")
        self.assertEqual(DOCUMENTATION_PIPELINE_VERSION, 3)
        self.assertEqual(DOCUMENTATION_MAX_OUTPUT_TOKENS, 4_096)
        self.assertLess(
            DOCUMENTATION_EVIDENCE_MAX_INPUT_TOKENS
            + DOCUMENTATION_MAX_OUTPUT_TOKENS,
            MAX_MODEL_CONTEXT_TOKENS,
        )

        config = documentation_generation_config()
        self.assertEqual(config.max_tokens, 4_096)
        self.assertEqual(config.temperature, 0)
        self.assertEqual(config.reasoning_effort, "none")
        self.assertEqual(
            config.extra_body,
            {"chat_template_kwargs": {"enable_thinking": False}},
        )

    def test_phase_wrapper_has_one_total_deadline_and_restores_solution(self) -> None:
        source = inspect.getsource(solve_then_document)
        self.assertEqual(
            source.count("time_limit(documentation_time_limit_seconds)"),
            1,
        )
        self.assertIn('"cybench.documentation_work"', source)
        self.assertIn("*solution_messages", source)
        self.assertIn("state.output = solution_output", source)
        self.assertIn("generate_documentation_submission(", source)
        self.assertIn("documentation_generation_config()", inspect.getsource(
            generate_documentation_submission
        ))

    def test_stage_inputs_progress_only_through_externalized_state(self) -> None:
        summary = ChatMessageUser(
            content="LATEST_COMPACTION_SENTINEL",
            metadata={"summary": True},
        )
        current = ChatMessageAssistant(content="CURRENT_WINDOW_SENTINEL")
        evidence_messages = documentation_evidence_input(
            [summary, current],
            "Loesungsphase beendet.",
        )
        evidence_text = "EXTERNALIZED_EVIDENCE_SENTINEL"
        drafts_messages = documentation_drafts_input(
            evidence_text,
            "Loesungsphase beendet.",
        )
        handoff = ChatMessageUser(content="HANDOFF_SENTINEL")
        final_messages = documentation_final_input(
            evidence_text,
            "EXTERNALIZED_DRAFTS_SENTINEL",
            handoff,
        )

        evidence_input_text = "\n".join(
            str(message.content) for message in evidence_messages
        )
        drafts_input_text = "\n".join(
            str(message.content) for message in drafts_messages
        )
        final_input_text = "\n".join(
            str(message.content) for message in final_messages
        )
        self.assertIn("LATEST_COMPACTION_SENTINEL", evidence_input_text)
        self.assertIn("CURRENT_WINDOW_SENTINEL", evidence_input_text)
        self.assertNotIn("LATEST_COMPACTION_SENTINEL", drafts_input_text)
        self.assertNotIn("CURRENT_WINDOW_SENTINEL", drafts_input_text)
        self.assertIn(evidence_text, drafts_input_text)
        self.assertNotIn("LATEST_COMPACTION_SENTINEL", final_input_text)
        self.assertNotIn("CURRENT_WINDOW_SENTINEL", final_input_text)
        self.assertIn(evidence_text, final_input_text)
        self.assertIn("EXTERNALIZED_DRAFTS_SENTINEL", final_input_text)
        self.assertIs(final_messages[-1], handoff)

    def test_exact_report_contract_requires_order_bodies_and_no_extra_heading(
        self,
    ) -> None:
        valid = documentation_report()
        self.assertEqual(validate_documentation_report(valid), [])

        empty_body = valid.replace(
            "## Ergebnis\nBelegter Inhalt.",
            "## Ergebnis\n",
        )
        self.assertTrue(validate_documentation_report(empty_body))
        self.assertTrue(
            validate_documentation_report(f"Vorspann\n{valid}")
        )
        self.assertTrue(
            validate_documentation_report(f"{valid}\n\n### Zusatz\nNein")
        )
        reversed_report = "\n\n".join(
            f"## {heading}\nInhalt"
            for heading in reversed(DOCUMENTATION_REQUIRED_HEADINGS)
        )
        self.assertTrue(validate_documentation_report(reversed_report))

    async def test_bounded_stage_has_no_tools_and_strips_marker(self) -> None:
        model = FakeDocumentationModel(
            f"Belegte Evidenz.\n{DOCUMENTATION_EVIDENCE_END_MARKER}"
        )
        messages = [ChatMessageUser(content="Aktives Fenster")]

        completion, metadata = await generate_documentation_stage(
            model,  # type: ignore[arg-type]
            messages,
            stage="evidence_extraction",
            end_marker=DOCUMENTATION_EVIDENCE_END_MARKER,
            maximum_input_tokens=1_000,
        )

        self.assertEqual(completion, "Belegte Evidenz.")
        self.assertEqual(metadata["input_tokens"], 100)
        self.assertEqual(metadata["max_output_tokens"], 4_096)
        self.assertEqual(len(model.calls), 1)
        self.assertEqual(model.calls[0]["tools"], [])
        self.assertEqual(model.calls[0]["tool_choice"], "none")
        config = model.calls[0]["config"]
        self.assertEqual(config.max_tokens, 4_096)
        self.assertEqual(config.temperature, 0)

    async def test_bounded_stage_rejects_truncation_and_oversized_input(
        self,
    ) -> None:
        missing_marker = FakeDocumentationModel("Unvollstaendige Evidenz")
        with self.assertRaises(DocumentationStageError):
            await generate_documentation_stage(
                missing_marker,  # type: ignore[arg-type]
                [ChatMessageUser(content="Fenster")],
                stage="evidence_extraction",
                end_marker=DOCUMENTATION_EVIDENCE_END_MARKER,
                maximum_input_tokens=1_000,
            )

        truncated = FakeDocumentationModel(
            f"Evidenz\n{DOCUMENTATION_EVIDENCE_END_MARKER}",
            stop_reason="max_tokens",
        )
        with self.assertRaises(DocumentationStageError):
            await generate_documentation_stage(
                truncated,  # type: ignore[arg-type]
                [ChatMessageUser(content="Fenster")],
                stage="evidence_extraction",
                end_marker=DOCUMENTATION_EVIDENCE_END_MARKER,
                maximum_input_tokens=1_000,
            )

        oversized = FakeDocumentationModel(
            f"Entwurf\n{DOCUMENTATION_DRAFTS_END_MARKER}",
            input_tokens=DOCUMENTATION_DERIVED_MAX_INPUT_TOKENS + 1,
        )
        with self.assertRaises(DocumentationStageError):
            await generate_documentation_stage(
                oversized,  # type: ignore[arg-type]
                [ChatMessageUser(content="Evidenz")],
                stage="section_drafts",
                end_marker=DOCUMENTATION_DRAFTS_END_MARKER,
                maximum_input_tokens=DOCUMENTATION_DERIVED_MAX_INPUT_TOKENS,
            )
        self.assertEqual(oversized.calls, [])

    async def test_final_submission_is_directly_config_bound_and_marked(
        self,
    ) -> None:
        report = documentation_report()
        model = FakeDocumentationModel("")
        model.output.message = SimpleNamespace(
            tool_calls=[
                ToolCall(
                    id="submit-1",
                    function="submit_documentation_report",
                    arguments={
                        "report": report,
                        "completion_marker": DOCUMENTATION_FINAL_END_MARKER,
                    },
                )
            ]
        )

        candidate, errors, metadata = await generate_documentation_submission(
            model,  # type: ignore[arg-type]
            [ChatMessageUser(content="Gebundene Evidenz und Entwuerfe")],
            stage="final_synthesis",
        )

        self.assertEqual(candidate, report)
        self.assertEqual(errors, [])
        self.assertTrue(metadata["submit_tool_only"])
        self.assertEqual(len(model.calls), 1)
        self.assertEqual(model.calls[0]["tool_choice"], "any")
        self.assertEqual(len(model.calls[0]["tools"]), 1)
        config = model.calls[0]["config"]
        self.assertEqual(config.max_tokens, 4_096)
        self.assertEqual(config.reasoning_effort, "none")

        model.output.message.tool_calls[0].arguments[
            "completion_marker"
        ] = "WRONG"
        _, marker_errors, _ = await generate_documentation_submission(
            model,  # type: ignore[arg-type]
            [ChatMessageUser(content="Gebundene Evidenz und Entwuerfe")],
            stage="final_validation_repair",
        )
        self.assertIn(
            "final submit completion marker is missing",
            marker_errors,
        )

        model.output.message.tool_calls = [
            ToolCall(
                id="submit-2",
                function="submit_documentation_report",
                arguments={
                    "report": report,
                    "completion_marker": DOCUMENTATION_FINAL_END_MARKER,
                },
            ),
            ToolCall(
                id="foreign-1",
                function="foreign_tool",
                arguments={},
            ),
        ]
        _, mixed_tool_errors, _ = await generate_documentation_submission(
            model,  # type: ignore[arg-type]
            [ChatMessageUser(content="Gebundene Evidenz und Entwuerfe")],
            stage="final_validation_repair",
        )
        self.assertIn(
            "final synthesis did not emit exactly one submit-only tool call",
            mixed_tool_errors,
        )


if __name__ == "__main__":
    unittest.main()

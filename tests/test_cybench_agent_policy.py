from __future__ import annotations

import unittest

from inspect_ai.agent import AgentPrompt

from evals.cybench import (
    AGENT_POLICY_BASELINE,
    AGENT_POLICY_EFFICIENT,
    AGENT_POLICY_NEUTRAL,
    GERMAN_EFFICIENT_ASSISTANT_PROMPT,
    GERMAN_NEUTRAL_ASSISTANT_PROMPT,
    GERMAN_NEUTRAL_CONTINUE_MESSAGE,
    GERMAN_NEUTRAL_INCORRECT_MESSAGE,
    GERMAN_NEUTRAL_TASK_REMINDER,
    _solution_runtime_messages,
    _solution_prompt,
    agent_policy_prompt_sha256,
)


class CybenchAgentPolicyTests(unittest.TestCase):
    def test_baseline_keeps_the_existing_string_prompt(self) -> None:
        prompt = _solution_prompt(AGENT_POLICY_BASELINE)

        self.assertIsInstance(prompt, str)
        self.assertIn("isolierten Kali-Linux-Umgebung", prompt)

    def test_efficient_policy_replaces_the_implicit_assistant_prompt(self) -> None:
        prompt = _solution_prompt(AGENT_POLICY_EFFICIENT)

        self.assertIsInstance(prompt, AgentPrompt)
        self.assertIsNone(prompt.handoff_prompt)
        self.assertEqual(prompt.assistant_prompt, GERMAN_EFFICIENT_ASSISTANT_PROMPT)
        self.assertIn("hoechstens vier kurzen Saetzen", prompt.assistant_prompt)
        self.assertIn("radare2", prompt.assistant_prompt)
        self.assertIn("Gesamttokenquote", prompt.assistant_prompt)
        self.assertNotIn("Prioritize parallel tool calls", prompt.assistant_prompt)
        self.assertIn("{submit}", prompt.submit_prompt)

    def test_neutral_policy_contains_protocol_without_solution_strategy(self) -> None:
        prompt = _solution_prompt(AGENT_POLICY_NEUTRAL)

        self.assertIsInstance(prompt, AgentPrompt)
        self.assertIsNone(prompt.handoff_prompt)
        self.assertEqual(prompt.assistant_prompt, GERMAN_NEUTRAL_ASSISTANT_PROMPT)
        self.assertIsNone(prompt.submit_prompt)
        combined = "\n".join(
            part
            for part in (prompt.instructions, prompt.assistant_prompt)
            if part is not None
        )
        self.assertIn("{submit}", combined)
        self.assertIn("isolierten Kali-Linux-Umgebung", combined)
        for strategy in (
            "Hypothese",
            "hoechstwertige",
            "radare2",
            "gezielte Ausschnitte",
            "zwei materiell",
            "Prioritize parallel tool calls",
        ):
            self.assertNotIn(strategy, combined)

    def test_neutral_loop_messages_only_express_language_and_protocol(self) -> None:
        reminder, continue_message, incorrect_message = _solution_runtime_messages(
            AGENT_POLICY_NEUTRAL
        )

        self.assertEqual(reminder, GERMAN_NEUTRAL_TASK_REMINDER)
        self.assertEqual(continue_message, GERMAN_NEUTRAL_CONTINUE_MESSAGE)
        self.assertEqual(incorrect_message, GERMAN_NEUTRAL_INCORRECT_MESSAGE)
        combined = "\n".join((reminder, continue_message, incorrect_message))
        for strategy in (
            "Hypothese",
            "naechsten sinnvollen Schritt",
            "Evidenz",
            "wiederhole",
            "redundante Laufzeitpruefung",
            "installieren",
        ):
            self.assertNotIn(strategy, combined)

    def test_neutral_prompt_contract_hash_is_stable(self) -> None:
        prompt_hash = agent_policy_prompt_sha256(AGENT_POLICY_NEUTRAL)

        self.assertRegex(prompt_hash, r"^[0-9a-f]{64}$")
        # The literal is filled from the reviewed prompt contract and catches
        # accidental semantic edits under the immutable neutral-v1 label.
        self.assertEqual(
            prompt_hash,
            "7c7f400f1b83ee644d49e9624eb799f1571cfff14b1be2b7e89cc42bdcf777dd",
        )

    def test_unknown_policy_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "unknown agent policy"):
            _solution_prompt("unknown-policy")


if __name__ == "__main__":
    unittest.main()

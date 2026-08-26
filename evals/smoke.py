"""Neutral compatibility gates for the model API and native tool calling.

These tasks measure transport compatibility only. They contain no challenge,
fixture, target service, flag, file-system probe, or cybersecurity scenario.
"""

from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.model import GenerateConfig
from inspect_ai.scorer import includes
from inspect_ai.solver import generate, use_tools
from inspect_ai.tool import Tool, ToolError, tool


DETERMINISTIC = GenerateConfig(
    temperature=0.0,
    top_p=1.0,
    seed=42,
    max_tokens=512,
    parallel_tool_calls=False,
)


@tool
def compatibility_echo() -> Tool:
    async def execute(value: str) -> str:
        """Return a fixed compatibility response for one exact input.

        Args:
            value: Must be exactly TOOL_REQUEST.

        Returns:
            The fixed string TOOL_OK.
        """
        if value != "TOOL_REQUEST":
            raise ToolError("The compatibility value must be TOOL_REQUEST.")
        return "TOOL_OK"

    return execute


@task
def llm_smoke() -> Task:
    """Prove that a plain request contains no tools and returns normally."""
    return Task(
        dataset=[
            Sample(
                id="llm-smoke",
                input='Reply with exactly "LLM_OK".',
                target="LLM_OK",
            )
        ],
        solver=generate(tool_calls="none"),
        scorer=includes(),
        config=DETERMINISTIC,
        message_limit=4,
        token_limit=1024,
        time_limit=60,
    )


@task
def native_tool_smoke() -> Task:
    """Exercise native tool calling without a lab or sandbox fixture."""
    return Task(
        dataset=[
            Sample(
                id="native-tool-smoke",
                input=(
                    "Use compatibility_echo with value TOOL_REQUEST. "
                    "Then answer only with the returned value. /no_think"
                ),
                target="TOOL_OK",
            )
        ],
        solver=[
            use_tools([compatibility_echo()]),
            generate(tool_calls="loop"),
        ],
        scorer=includes(),
        config=DETERMINISTIC,
        message_limit=8,
        token_limit=4096,
        time_limit=60,
    )

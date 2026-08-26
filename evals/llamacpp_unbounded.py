"""OpenAI-compatible llama.cpp provider without an API read deadline.

This provider is deliberately opt-in.  Inspect's stock OpenAI provider leaves
the OpenAI SDK default in place when ``client_timeout`` is omitted; that
default is currently 600 seconds.  Supplying an HTTP client whose timeout is
explicitly disables only its read deadline so long local generations are
context-owned rather than wall-clock-owned. Connect, write, and pool stalls
remain bounded, and benchmark runs that use ``openai-api`` are unchanged.
"""

from __future__ import annotations

from typing import Any

from inspect_ai.model import modelapi
from inspect_ai.model._providers.openai import OpenAIAPI
from httpx2 import Timeout
from openai import DefaultAsyncHttpxClient


LLAMACPP_UNBOUNDED_PROVIDER = "llamacpp-unbounded-v1"


@modelapi(LLAMACPP_UNBOUNDED_PROVIDER)
class LlamaCppUnboundedAPI(OpenAIAPI):
    """Pinned provider with unbounded reads and bounded infrastructure stalls."""

    def __init__(
        self,
        model_name: str,
        base_url: str | None = None,
        api_key: str | None = None,
        **model_args: Any,
    ) -> None:
        if "client_timeout" in model_args:
            raise ValueError(
                "llamacpp-unbounded-v1 owns the API timeout policy; "
                "client_timeout must not be supplied"
            )
        super().__init__(
            model_name=model_name,
            base_url=base_url,
            api_key=api_key,
            http_client=DefaultAsyncHttpxClient(
                timeout=Timeout(
                    timeout=None,
                    connect=15,
                    write=60,
                    pool=60,
                )
            ),
            **model_args,
        )

"""Small deterministic OpenAI-compatible server for local wiring tests only."""

from __future__ import annotations

import argparse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
from typing import Any


DOCUMENTATION_EVIDENCE_END_MARKER = "[EVIDENZ_ENDE]"
DOCUMENTATION_DRAFTS_END_MARKER = "[ABSCHNITTE_ENDE]"
DOCUMENTATION_FINAL_END_MARKER = "[BERICHT_ENDE]"
DOCUMENTATION_HEADINGS = (
    "Ergebnis",
    "Vorgehen und Evidenz",
    "Befehle und Artefakte",
    "Erfolglose Versuche",
    "Reproduktionsschritte",
)


def canonical_documentation_report() -> str:
    bodies = (
        "Der deterministische Harness-Versuch blieb erwartungsgemaess ungeloest; "
        "es wurde keine gueltige Challenge-Antwort bestaetigt.",
        "Das lokale Dummy-Modell durchlief den vorgesehenen Loesungs- und "
        "Dokumentationspfad ohne externe Recherche.",
        "Der lokale Harness und der OpenAI-kompatible Mock-Endpunkt wurden "
        "verwendet; weitere Artefakte wurden nicht erzeugt.",
        "Die Platzhalterantwort LLM_OK ist keine gueltige Challenge-Loesung.",
        "Den lokalen run-cybench-harness-smoke.sh erneut ausfuehren.",
    )
    return "\n\n".join(
        f"## {heading}\n{body}"
        for heading, body in zip(DOCUMENTATION_HEADINGS, bodies, strict=True)
    )


class MockHandler(BaseHTTPRequestHandler):
    server_version = "QwenEvalMock/1.0"

    def log_message(self, format: str, *args: object) -> None:
        print(f"mock-api: {self.address_string()} - {format % args}", flush=True)

    def _json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self) -> bool:
        expected = f"Bearer {self.server.api_key}"
        return self.headers.get("Authorization") == expected

    def do_GET(self) -> None:  # noqa: N802
        if not self._authorized():
            self._json(HTTPStatus.UNAUTHORIZED, {"error": {"message": "unauthorized"}})
            return
        if self.path == "/health":
            self._json(HTTPStatus.OK, {"status": "ok"})
            return
        if self.path == "/v1/models":
            self._json(
                HTTPStatus.OK,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": "mock-model",
                            "object": "model",
                            "created": 0,
                            "owned_by": "local",
                        }
                    ],
                },
            )
            return
        self._json(HTTPStatus.NOT_FOUND, {"error": {"message": "not found"}})

    def do_POST(self) -> None:  # noqa: N802
        if not self._authorized():
            self._json(HTTPStatus.UNAUTHORIZED, {"error": {"message": "unauthorized"}})
            return
        if self.path != "/v1/chat/completions":
            self._json(HTTPStatus.NOT_FOUND, {"error": {"message": "not found"}})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError):
            self._json(HTTPStatus.BAD_REQUEST, {"error": {"message": "invalid JSON"}})
            return

        self.server.trace(body)
        messages = body.get("messages", [])
        tool_messages = [message for message in messages if message.get("role") == "tool"]
        tools = body.get("tools") or []
        tool_names = [
            tool.get("function", {}).get("name")
            for tool in tools
            if tool.get("type") == "function"
        ]
        transcript = "\n".join(
            str(message.get("content") or "") for message in messages
        )

        if body.get("response_format"):
            self._completion(
                body,
                content=json.dumps({"title": "Compatibility smoke"}),
                finish_reason="stop",
            )
            return

        if "submit_documentation_report" in tool_names:
            self._completion(
                body,
                tool_name="submit_documentation_report",
                tool_arguments={
                    "report": canonical_documentation_report(),
                    "completion_marker": DOCUMENTATION_FINAL_END_MARKER,
                },
                finish_reason="tool_calls",
            )
            return

        # ReAct can ask again after an incorrect submission. Keep exercising
        # the native submit path rather than falling back to plain chat text.
        if "submit" in tool_names:
            answer = (
                "Ergebnis\nDer Kompatibilitätstest blieb erwartungsgemäß "
                "ungelöst.\n\nVorgehen und Evidenz\nDas deterministische "
                "Dummy-Modell reichte den vorgesehenen Platzhalter ein.\n\n"
                "Befehle und Artefakte\nKeine.\n\nErfolglose Versuche\n"
                "Nur die Platzhalterantwort.\n\nReproduktionsschritte\n"
                "Den lokalen Harness-Test ausführen."
                if (
                    "reproduction steps" in transcript.lower()
                    or "reproduktionsschritte" in transcript.lower()
                )
                else "LLM_OK"
            )
            self._completion(
                body,
                tool_name="submit",
                tool_arguments={"answer": answer},
                finish_reason="tool_calls",
            )
            return

        if not tools and DOCUMENTATION_EVIDENCE_END_MARKER in transcript:
            self._completion(
                body,
                content=(
                    "- Ergebnis: Die Platzhalterantwort LLM_OK wurde im lokalen "
                    "Harness verwendet und ist keine bestaetigte Challenge-Loesung.\n"
                    "- Evidenz: Es gab keine externe Recherche und keine gueltige "
                    "Einreichung.\n"
                    f"{DOCUMENTATION_EVIDENCE_END_MARKER}"
                ),
                finish_reason="stop",
            )
            return

        if not tools and DOCUMENTATION_DRAFTS_END_MARKER in transcript:
            self._completion(
                body,
                content=(
                    f"{canonical_documentation_report()}\n"
                    f"{DOCUMENTATION_DRAFTS_END_MARKER}"
                ),
                finish_reason="stop",
            )
            return

        if tool_messages:
            tool_content = str(tool_messages[-1].get("content", "")).strip()
            if "TOOL_OK" in tool_content:
                content = "TOOL_OK"
            else:
                content = "TOOL_RESULT_INVALID"
            self._completion(body, content=content, finish_reason="stop")
            return

        if tools:
            if "compatibility_echo" in tool_names:
                self._completion(
                    body,
                    tool_name="compatibility_echo",
                    tool_arguments={"value": "TOOL_REQUEST"},
                    finish_reason="tool_calls",
                )
                return
            # General agent harnesses advertise their complete tool catalog on
            # every request. Returning a normal assistant message verifies that
            # transport without asking the harness to execute an unrelated tool.
            self._completion(body, content="LLM_OK", finish_reason="stop")
            return

        self._completion(body, content="LLM_OK", finish_reason="stop")

    def _completion(
        self,
        request: dict[str, Any],
        *,
        content: str | None = None,
        tool_name: str | None = None,
        tool_arguments: dict[str, Any] | None = None,
        finish_reason: str,
    ) -> None:
        if request.get("stream"):
            self._stream_completion(
                request,
                content=content,
                tool_name=tool_name,
                tool_arguments=tool_arguments,
                finish_reason=finish_reason,
            )
            return

        message: dict[str, Any] = {"role": "assistant", "content": content}
        if tool_name is not None:
            message["tool_calls"] = [
                {
                    "id": "call_local_1",
                    "type": "function",
                    "function": {
                        "name": tool_name,
                        "arguments": json.dumps(tool_arguments or {}, separators=(",", ":")),
                    },
                }
            ]
        payload = {
            "id": "chatcmpl-local",
            "object": "chat.completion",
            "created": 0,
            "model": request.get("model", "mock-model"),
            "system_fingerprint": "local-mock-v1",
            "choices": [
                {
                    "index": 0,
                    "message": message,
                    "finish_reason": finish_reason,
                    "logprobs": None,
                }
            ],
            "usage": {
                "prompt_tokens": 1,
                "completion_tokens": 1,
                "total_tokens": 2,
            },
        }
        self._json(HTTPStatus.OK, payload)

    def _stream_completion(
        self,
        request: dict[str, Any],
        *,
        content: str | None,
        tool_name: str | None,
        tool_arguments: dict[str, Any] | None,
        finish_reason: str,
    ) -> None:
        completion_id = "chatcmpl-local"
        model = request.get("model", "mock-model")
        delta: dict[str, Any] = {"role": "assistant", "content": content}
        if tool_name is not None:
            delta["content"] = None
            delta["tool_calls"] = [
                {
                    "index": 0,
                    "id": "call_local_1",
                    "type": "function",
                    "function": {
                        "name": tool_name,
                        "arguments": json.dumps(
                            tool_arguments or {}, separators=(",", ":")
                        ),
                    },
                }
            ]

        chunks = [
            {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": 0,
                "model": model,
                "system_fingerprint": "local-mock-v1",
                "choices": [
                    {
                        "index": 0,
                        "delta": delta,
                        "finish_reason": None,
                        "logprobs": None,
                    }
                ],
            },
            {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": 0,
                "model": model,
                "system_fingerprint": "local-mock-v1",
                "choices": [
                    {
                        "index": 0,
                        "delta": {},
                        "finish_reason": finish_reason,
                        "logprobs": None,
                    }
                ],
            },
            {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": 0,
                "model": model,
                "system_fingerprint": "local-mock-v1",
                "choices": [],
                "usage": {
                    "prompt_tokens": 1,
                    "completion_tokens": 1,
                    "total_tokens": 2,
                },
            },
        ]

        self.send_response(HTTPStatus.OK.value)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        for chunk in chunks:
            data = json.dumps(chunk, separators=(",", ":")).encode("utf-8")
            self.wfile.write(b"data: " + data + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


class MockServer(ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], api_key: str, trace_file: Path):
        super().__init__(address, MockHandler)
        self.api_key = api_key
        self.trace_file = trace_file

    def trace(self, body: dict[str, Any]) -> None:
        self.trace_file.parent.mkdir(parents=True, exist_ok=True)
        with self.trace_file.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(body, ensure_ascii=False, separators=(",", ":")))
            handle.write("\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--trace-file", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    api_key = os.environ.get("MOCK_API_KEY")
    if not api_key:
        raise SystemExit("MOCK_API_KEY must be set")
    server = MockServer(("127.0.0.1", args.port), api_key, args.trace_file)
    print(f"mock-api: listening on http://127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

from __future__ import annotations

import unittest

from inspect_ai.model import get_model


class CybenchModelTimeoutTests(unittest.IsolatedAsyncioTestCase):
    async def test_openai_compatible_client_timeout_reaches_http_read_timeout(
        self,
    ) -> None:
        model = get_model(
            "openai-api/llamacpp/timeout-contract-test",
            base_url="http://127.0.0.1:1/v1",
            api_key="unit-test-only",
            memoize=False,
            client_timeout=7_500,
        )
        try:
            self.assertEqual(model.model_args["client_timeout"], 7_500)
            self.assertEqual(model.api.client_timeout, 7_500)
            self.assertEqual(model.api.client._client.timeout.read, 7_500)
        finally:
            await model.api.aclose()


if __name__ == "__main__":
    unittest.main()

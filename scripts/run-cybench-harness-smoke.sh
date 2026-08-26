#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
venv_dir="${HOME}/.local/share/qwen-eval/.venv"
cache_dir="${HOME}/.local/share/qwen-eval/inspect-evals-cache"
uv_bin="${HOME}/.local/bin/uv"
run_id="$(date -u +%Y%m%dT%H%M%SZ)"
mock_artifact_dir="${project_dir}/artifacts/mock-api/${run_id}-cybench-e2e"
trace_file="${mock_artifact_dir}/requests.jsonl"
log_dir="${project_dir}/artifacts/logs/${run_id}-cybench"
mock_log="${mock_artifact_dir}/server.log"
lock_dir="${HOME}/.local/share/qwen-eval"
lock_file="${lock_dir}/cybench-harness-smoke.lock"
model_api_timeout_policy="phase-limit-owned-v1"
model_api_client_timeout_seconds="7500"
mock_pid=""

cleanup() {
  if [[ -n "${mock_pid}" ]] && kill -0 "${mock_pid}" 2>/dev/null; then
    kill "${mock_pid}"
    wait "${mock_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

cd "${project_dir}"
mapfile -t toolchain_metadata < <(
  "${uv_bin}" run python - <<'PY'
from evals.cybench_toolchains import get_agent_toolchain

toolchain = get_agent_toolchain("upstream-static-v1")
print(toolchain.identifier)
print(toolchain.agent_image)
print(toolchain.agent_image.rsplit("@", 1)[1])
print(toolchain.manifest_sha256)
PY
)
if ((${#toolchain_metadata[@]} != 4)); then
  echo "Unable to resolve the agent toolchain metadata." >&2
  exit 2
fi
agent_prompt_sha256="$(
  "${uv_bin}" run python - <<'PY'
from evals.cybench import AGENT_POLICY_NEUTRAL, agent_policy_prompt_sha256

print(agent_policy_prompt_sha256(AGENT_POLICY_NEUTRAL))
PY
)"
[[ "${agent_prompt_sha256}" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Unable to resolve the neutral agent prompt SHA-256 contract." >&2
  exit 2
}
"${project_dir}/scripts/check-local.sh"
mkdir -p "${lock_dir}"
exec 9>"${lock_file}"
flock -n 9 || {
  echo "Another Cybench harness smoke is already running." >&2
  exit 2
}
export UV_PROJECT_ENVIRONMENT="${venv_dir}"
export INSPECT_EVALS_CACHE_DIR="${cache_dir}"
export PYTHONPATH="${project_dir}${PYTHONPATH:+:${PYTHONPATH}}"
export MOCK_API_KEY="local-mock-only"
export MOCK_BASE_URL="http://127.0.0.1:18081/v1"
mkdir -p "${log_dir}" "${mock_artifact_dir}"

"${uv_bin}" run python scripts/mock_openai_server.py \
  --port 18081 \
  --trace-file "${trace_file}" \
  9>&- \
  >"${mock_log}" 2>&1 &
mock_pid="$!"

mock_ready="false"
for _ in $(seq 1 40); do
  if ! kill -0 "${mock_pid}" 2>/dev/null; then
    echo "Mock API server exited before becoming ready:" >&2
    sed -n '1,80p' "${mock_log}" >&2
    exit 1
  fi
  if curl --fail --silent \
    --header "Authorization: Bearer ${MOCK_API_KEY}" \
    http://127.0.0.1:18081/health >/dev/null; then
    mock_ready="true"
    break
  fi
  sleep 0.25
done

[[ "${mock_ready}" == "true" ]] || {
  echo "Mock API server did not become ready." >&2
  exit 1
}

"${uv_bin}" run inspect eval evals/cybench.py@cybench_isolated \
  --model openai-api/mock/mock-model \
  -T eval_names=avatar \
  -T variant_names=hard \
  -T harness_smoke=true \
  -T agent_policy=neutral-v1 \
  -T agent_toolchain=upstream-static-v1 \
  --limit 1 \
  --max-connections 1 \
  --max-samples 1 \
  --max-sandboxes 1 \
  --max-retries 0 \
  --timeout 30 \
  --message-limit 160 \
  --token-limit 196608 \
  --time-limit 120 \
  --temperature 0 \
  --no-parallel-tool-calls \
  --max-tool-output 16384 \
  --log-format eval \
  --log-dir "${log_dir}" \
  --metadata official_scorer=includes \
  --metadata selection_profile=harness-smoke \
  --metadata selection_scored=false \
  --metadata "orchestration_launch_id=${run_id}" \
  --metadata agent_policy_version=neutral-v1 \
  --metadata "agent_prompt_sha256=${agent_prompt_sha256}" \
  --metadata "agent_toolchain_id=${toolchain_metadata[0]}" \
  --metadata "agent_toolchain_image=${toolchain_metadata[1]}" \
  --metadata "agent_toolchain_image_digest=${toolchain_metadata[2]}" \
  --metadata "agent_toolchain_manifest_sha256=${toolchain_metadata[3]}" \
  --metadata agent_toolchain_runtime_installation=false \
  --metadata agent_reasoning_effort=provider_default \
  --metadata agent_prompt_mode=german_neutral_minimal \
  --metadata "model_api_timeout_policy=${model_api_timeout_policy}" \
  --metadata "model_api_client_timeout_seconds=${model_api_client_timeout_seconds}" \
  --metadata documentation_pipeline_id=iterative-active-window \
  --metadata documentation_pipeline_version=3 \
  --metadata main_generation_limit=wall_time_only \
  --metadata tool_output_max_bytes=16384 \
  --metadata tool_output_strategy=default_truncation \
  --metadata context_management=summary_compaction \
  --metadata context_compaction_threshold_tokens=160000 \
  --metadata context_compaction_summary_target_tokens=1200 \
  --metadata context_compaction_summary_max_tokens=4096 \
  --metadata context_compaction_summary_max_attempts=2 \
  --metadata context_compaction_summary_completion=best_nonempty_after_repair \
  --metadata context_compaction_summary_retry_scope=draft_only_when_available \
  --metadata context_compaction_summary_priority=next_steps_first \
  --metadata context_compaction_summary_reasoning=disabled \
  --metadata model_context_tokens=262144 \
  --display plain \
  -M stream=false \
  -M strict_tools=false \
  -M "client_timeout=${model_api_client_timeout_seconds}"

"${uv_bin}" run python scripts/cybench_run_health.py \
  "${log_dir}" \
  --expected-samples 1 \
  --expected-model openai-api/mock/mock-model \
  --expected-agent-policy neutral-v1 \
  --expected-agent-toolchain upstream-static-v1 \
  --expected-model-api-timeout-policy phase-limit-owned-v1 \
  --expected-model-api-client-timeout-seconds 7500 \
  --expected-documentation-pipeline-id iterative-active-window \
  --expected-documentation-pipeline-version 3 \
  --expected-tool-output-max-bytes 16384 \
  --expected-context-management summary_compaction \
  --expected-compaction-threshold-tokens 160000 \
  --expected-compaction-summary-max-tokens 4096 \
  --expected-model-context-tokens 262144 \
  --require-complete

echo "Official Cybench harness smoke passed; an incorrect score is expected from the dummy model."
echo "Inspect log: ${log_dir}"

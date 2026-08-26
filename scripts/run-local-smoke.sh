#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
venv_dir="${HOME}/.local/share/qwen-eval/.venv"
uv_bin="${HOME}/.local/bin/uv"
run_id="$(date -u +%Y%m%dT%H%M%SZ)"
log_dir="${project_dir}/artifacts/logs/${run_id}"
trace_file="${project_dir}/artifacts/mock-api/${run_id}.jsonl"
mock_log="${project_dir}/artifacts/mock-api/${run_id}.log"
mock_pid=""

cleanup() {
  if [[ -n "${mock_pid}" ]] && kill -0 "${mock_pid}" 2>/dev/null; then
    kill "${mock_pid}"
    wait "${mock_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

cd "${project_dir}"
"${project_dir}/scripts/check-local.sh"

export UV_PROJECT_ENVIRONMENT="${venv_dir}"
export MOCK_API_KEY="local-mock-only"
export MOCK_BASE_URL="http://127.0.0.1:18080/v1"
export INSPECT_LOG_LEVEL="warning"
export INSPECT_LOG_LEVEL_TRANSCRIPT="info"
mkdir -p "${log_dir}" "$(dirname -- "${trace_file}")"

"${uv_bin}" run python scripts/mock_openai_server.py \
  --port 18080 \
  --trace-file "${trace_file}" \
  >"${mock_log}" 2>&1 &
mock_pid="$!"

for _ in $(seq 1 40); do
  if curl --fail --silent \
    --header "Authorization: Bearer ${MOCK_API_KEY}" \
    http://127.0.0.1:18080/health >/dev/null; then
    break
  fi
  sleep 0.25
done

curl --fail --silent \
  --header "Authorization: Bearer ${MOCK_API_KEY}" \
  http://127.0.0.1:18080/health >/dev/null

"${uv_bin}" run inspect eval evals/smoke.py \
  --model openai-api/mock/mock-model \
  --temperature 0 \
  --top-p 1 \
  --seed 42 \
  --no-parallel-tool-calls \
  --max-connections 1 \
  --max-samples 1 \
  --max-retries 0 \
  --timeout 30 \
  --log-model-api \
  --log-format eval \
  --log-dir "${log_dir}" \
  -M stream=false \
  -M strict_tools=false

"${uv_bin}" run python scripts/verify_eval_logs.py "${log_dir}"

echo "Smoke tests completed."
echo "Inspect logs: ${log_dir}"
echo "Mock API trace: ${trace_file}"

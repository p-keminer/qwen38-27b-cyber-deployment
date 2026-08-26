#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
venv_dir="${HOME}/.local/share/qwen-eval/.venv"
uv_bin="${HOME}/.local/bin/uv"
model_id="${1:-qwen3.8-27b}"
base_url="${LLAMACPP_BASE_URL:-http://127.0.0.1:18080/v1}"
run_id="$(date -u +%Y%m%dT%H%M%SZ)"
log_dir="${project_dir}/artifacts/logs/${run_id}-llamacpp"
metadata_dir="${log_dir}/server"

cd "${project_dir}"
"${project_dir}/scripts/check-local.sh"

[[ -n "${LLAMACPP_API_KEY:-}" ]] || {
  echo "LLAMACPP_API_KEY is required and must be loaded outside Git." >&2
  exit 1
}
[[ "${base_url}" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+/v1$ ]] || {
  echo "Refusing non-loopback endpoint: ${base_url}" >&2
  echo "Open an SSH tunnel and use http://127.0.0.1:PORT/v1." >&2
  exit 1
}

export UV_PROJECT_ENVIRONMENT="${venv_dir}"
export LLAMACPP_BASE_URL="${base_url}"
export INSPECT_LOG_LEVEL="warning"
export INSPECT_LOG_LEVEL_TRANSCRIPT="info"
mkdir -p "${metadata_dir}"

origin="${base_url%/v1}"
curl_args=(
  --fail
  --silent
  --show-error
  --max-time 15
  --header "Authorization: Bearer ${LLAMACPP_API_KEY}"
)
curl "${curl_args[@]}" "${origin}/health" >"${metadata_dir}/health.json"
curl "${curl_args[@]}" "${origin}/props" >"${metadata_dir}/props.json"
curl "${curl_args[@]}" "${base_url}/models" >"${metadata_dir}/models.json"

"${uv_bin}" run inspect eval evals/smoke.py \
  --model "openai-api/llamacpp/${model_id}" \
  --temperature 0 \
  --top-p 1 \
  --seed 42 \
  --no-parallel-tool-calls \
  --max-connections 1 \
  --max-samples 1 \
  --max-retries 0 \
  --timeout 60 \
  --log-model-api \
  --log-format eval \
  --log-dir "${log_dir}" \
  -M stream=false \
  -M strict_tools=false

"${uv_bin}" run python scripts/verify_eval_logs.py "${log_dir}"

echo "Remote llama.cpp compatibility gate passed for ${model_id}."
echo "Inspect logs and server metadata: ${log_dir}"

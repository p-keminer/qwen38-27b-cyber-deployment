#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
venv_dir="${HOME}/.local/share/qwen-eval/.venv"
cache_dir="${HOME}/.local/share/qwen-eval/inspect-evals-cache"
uv_bin="${HOME}/.local/bin/uv"
model_id="${1:?model id is required}"
shift

limit="1"
eval_names=""
solve_time_limit_seconds="7200"
documentation_time_limit_seconds="1800"
selection_profile="default-single"
selection_scored="true"
agent_policy="neutral-v1"
agent_toolchain="upstream-static-v1"
runtime_mode="benchmark-v1"
model_api_timeout_policy="phase-limit-owned-v1"
model_api_client_timeout_margin_seconds="300"
run_id=""
while (($#)); do
  case "$1" in
    --all)
      limit=""
      shift
      ;;
    --challenge)
      eval_names="${2:?--challenge requires a value}"
      shift 2
      ;;
    --limit)
      limit="${2:?--limit requires a value}"
      shift 2
      ;;
    --solve-time-limit-seconds)
      solve_time_limit_seconds="${2:?--solve-time-limit-seconds requires a value}"
      shift 2
      ;;
    --documentation-time-limit-seconds)
      documentation_time_limit_seconds="${2:?--documentation-time-limit-seconds requires a value}"
      shift 2
      ;;
    --selection-profile)
      selection_profile="${2:?--selection-profile requires a value}"
      shift 2
      ;;
    --selection-scored)
      selection_scored="${2:?--selection-scored requires a value}"
      shift 2
      ;;
    --agent-policy)
      agent_policy="${2:?--agent-policy requires a value}"
      shift 2
      ;;
    --agent-toolchain)
      agent_toolchain="${2:?--agent-toolchain requires a value}"
      shift 2
      ;;
    --runtime-mode)
      runtime_mode="${2:?--runtime-mode requires a value}"
      shift 2
      ;;
    --run-id)
      run_id="${2:?--run-id requires a value}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

[[ "${model_id}" =~ ^[a-zA-Z0-9._-]+$ ]] || {
  echo "Invalid model id: ${model_id}" >&2
  exit 2
}
[[ -z "${eval_names}" || "${eval_names}" =~ ^[a-z0-9_,]+$ ]] || {
  echo "Invalid Cybench challenge list: ${eval_names}" >&2
  exit 2
}
[[ -z "${limit}" || "${limit}" =~ ^[1-9][0-9]*$ ]] || {
  echo "Invalid limit: ${limit}" >&2
  exit 2
}
[[ "${solve_time_limit_seconds}" =~ ^[1-9][0-9]*$ ]] || {
  echo "Invalid solution time limit: ${solve_time_limit_seconds}" >&2
  exit 2
}
[[ "${documentation_time_limit_seconds}" =~ ^[1-9][0-9]*$ ]] || {
  echo "Invalid documentation time limit: ${documentation_time_limit_seconds}" >&2
  exit 2
}
[[ "${selection_profile}" =~ ^[a-z0-9-]+$ ]] || {
  echo "Invalid selection profile: ${selection_profile}" >&2
  exit 2
}
[[ "${selection_scored}" == "true" || "${selection_scored}" == "false" ]] || {
  echo "Invalid selection-scored value: ${selection_scored}" >&2
  exit 2
}
[[ "${agent_policy}" == "neutral-v1" || "${agent_policy}" == "baseline-v1" || "${agent_policy}" == "efficient-v2" ]] || {
  echo "Invalid agent policy: ${agent_policy}" >&2
  exit 2
}
[[ "${agent_toolchain}" == "upstream-static-v1" ]] || {
  echo "Invalid agent toolchain: ${agent_toolchain}" >&2
  exit 2
}
[[ "${runtime_mode}" == "benchmark-v1" || "${runtime_mode}" == "unbounded-interactive-v1" ]] || {
  echo "Invalid runtime mode: ${runtime_mode}" >&2
  exit 2
}
[[ -z "${run_id}" || "${run_id}" =~ ^[A-Za-z0-9-]+$ ]] || {
  echo "Invalid run id: ${run_id}" >&2
  exit 2
}
sample_time_limit_seconds="none"
model_api_client_timeout_seconds="none"
model_provider="openai-api/llamacpp"
main_generation_limit="wall_time_only"
tool_execution_timeout_seconds="180"
sample_time_limit_args=()
model_client_timeout_args=()
if [[ "${runtime_mode}" == "benchmark-v1" ]]; then
  ((solve_time_limit_seconds >= 7200)) || {
    echo "The solution phase must allow at least 7200 seconds." >&2
    exit 2
  }
  ((documentation_time_limit_seconds >= 1800)) || {
    echo "The documentation phase must allow at least 1800 seconds." >&2
    exit 2
  }
  if [[ "${selection_scored}" == "true" ]] && ((solve_time_limit_seconds != 7200)); then
    echo "Scored Cybench profiles require exactly 7200 solution seconds." >&2
    exit 2
  fi
  sample_time_limit_seconds=$((
    solve_time_limit_seconds + documentation_time_limit_seconds + 300
  ))
  model_api_client_timeout_seconds=$((
    solve_time_limit_seconds + model_api_client_timeout_margin_seconds
  ))
  sample_time_limit_args=(--time-limit "${sample_time_limit_seconds}")
  model_client_timeout_args=(
    -M "client_timeout=${model_api_client_timeout_seconds}"
  )
else
  if [[ "${selection_scored}" != "false" ]]; then
    echo "unbounded-interactive-v1 is deliberately unscored; pass --selection-scored false." >&2
    exit 2
  fi
  model_provider="llamacpp-unbounded-v1"
  model_api_timeout_policy="unbounded-interactive-v1"
  main_generation_limit="physical_context_only"
  tool_execution_timeout_seconds="none"
fi

cd "${project_dir}"
mapfile -t toolchain_metadata < <(
  "${uv_bin}" run python - "${agent_toolchain}" <<'PY'
import sys

from evals.cybench_toolchains import get_agent_toolchain

toolchain = get_agent_toolchain(sys.argv[1])
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
toolchain_id="${toolchain_metadata[0]}"
toolchain_image="${toolchain_metadata[1]}"
toolchain_image_digest="${toolchain_metadata[2]}"
toolchain_manifest_sha256="${toolchain_metadata[3]}"
agent_prompt_sha256="$(
  "${uv_bin}" run python - "${agent_policy}" <<'PY'
import sys

from evals.cybench import agent_policy_prompt_sha256

print(agent_policy_prompt_sha256(sys.argv[1]))
PY
)"
[[ "${agent_prompt_sha256}" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Unable to resolve the agent prompt SHA-256 contract." >&2
  exit 2
}
"${project_dir}/scripts/check-local.sh"
model_context_tokens="$(
  jq -er --arg alias "${model_id}" \
    '.models[] | select(.alias == $alias) | .context_size' \
    "${project_dir}/config/models.json"
)"
[[ "${model_context_tokens}" =~ ^[1-9][0-9]*$ ]] || {
  echo "Invalid model context declaration: ${model_context_tokens}" >&2
  exit 2
}
[[ -n "${LLAMACPP_API_KEY:-}" ]] || {
  echo "LLAMACPP_API_KEY is required and must be loaded outside Git." >&2
  exit 1
}
base_url="${LLAMACPP_BASE_URL:-http://127.0.0.1:18080/v1}"
[[ "${base_url}" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+/v1$ ]] || {
  echo "Refusing non-loopback endpoint: ${base_url}" >&2
  exit 1
}

export UV_PROJECT_ENVIRONMENT="${venv_dir}"
export INSPECT_EVALS_CACHE_DIR="${cache_dir}"
export PYTHONPATH="${project_dir}${PYTHONPATH:+:${PYTHONPATH}}"
export LLAMACPP_BASE_URL="${base_url}"
export INSPECT_LOG_LEVEL="warning"
export INSPECT_LOG_LEVEL_TRANSCRIPT="info"
if [[ -z "${run_id}" ]]; then
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(tr -d -- '-' </proc/sys/kernel/random/uuid)"
fi
log_dir="${project_dir}/artifacts/logs/${run_id}-cybench"
if [[ -e "${log_dir}" ]]; then
  echo "Refusing an existing Cybench launch directory: ${log_dir}" >&2
  exit 2
fi
mkdir "${log_dir}"

"${uv_bin}" run python -m scripts.prepare_cybench \
  --agent-toolchain "${agent_toolchain}" \
  --skip-images \
  --require-images

eval_args=(
  evals/cybench.py@cybench_isolated
  --model "${model_provider}/${model_id}"
  -T variant_names=hard
  -T "solve_time_limit_seconds=${solve_time_limit_seconds}"
  -T "documentation_time_limit_seconds=${documentation_time_limit_seconds}"
  -T "agent_policy=${agent_policy}"
  -T "agent_toolchain=${agent_toolchain}"
  --temperature 0
  --top-p 1
  --seed 42
  --no-parallel-tool-calls
  --max-tool-output 16384
  --max-connections 1
  --max-samples 1
  --max-sandboxes 1
  --max-retries 2
  --no-fail-on-error
  --score-on-error
  "${sample_time_limit_args[@]}"
  --log-model-api
  --log-format eval
  --log-dir "${log_dir}"
  --tags "qwen-eval,cybench,external,isolated,profile-${selection_profile},policy-${agent_policy}"
  --metadata benchmark_source=inspect-evals-0.18.0
  --metadata official_scorer=includes
  --metadata sandbox_egress=blocked
  --metadata sample_context=fresh
  --metadata interaction_language=de
  --metadata "agent_policy_version=${agent_policy}"
  --metadata "agent_prompt_sha256=${agent_prompt_sha256}"
  --metadata "agent_toolchain_id=${toolchain_id}"
  --metadata "agent_toolchain_image=${toolchain_image}"
  --metadata "agent_toolchain_image_digest=${toolchain_image_digest}"
  --metadata "agent_toolchain_manifest_sha256=${toolchain_manifest_sha256}"
  --metadata agent_toolchain_runtime_installation=false
  --metadata "main_generation_limit=${main_generation_limit}"
  --metadata tool_output_max_bytes=16384
  --metadata context_management=summary_compaction
  --metadata context_compaction_threshold_tokens=160000
  --metadata context_compaction_summary_target_tokens=1200
  --metadata context_compaction_summary_max_tokens=4096
  --metadata context_compaction_summary_max_attempts=2
  --metadata context_compaction_summary_completion=best_nonempty_after_repair
  --metadata context_compaction_summary_retry_scope=draft_only_when_available
  --metadata context_compaction_summary_priority=next_steps_first
  --metadata context_compaction_summary_reasoning=disabled
  --metadata "model_context_tokens=${model_context_tokens}"
  --metadata "selection_profile=${selection_profile}"
  --metadata "orchestration_launch_id=${run_id}"
  --metadata "selection_scored=${selection_scored}"
  --metadata "solve_time_limit_seconds=${solve_time_limit_seconds}"
  --metadata "documentation_time_limit_seconds=${documentation_time_limit_seconds}"
  --metadata "model_api_timeout_policy=${model_api_timeout_policy}"
  --metadata "model_api_client_timeout_seconds=${model_api_client_timeout_seconds}"
  --metadata documentation_pipeline_id=iterative-active-window
  --metadata documentation_pipeline_version=3
  --detach
  --json
  -M stream=false
  -M strict_tools=false
  "${model_client_timeout_args[@]}"
)
if [[ "${runtime_mode}" == "unbounded-interactive-v1" ]]; then
  eval_args+=(
    -T "runtime_mode=${runtime_mode}"
    --metadata "runtime_mode=${runtime_mode}"
    --metadata "tool_execution_timeout_seconds=${tool_execution_timeout_seconds}"
  )
fi
case "${agent_policy}" in
  efficient-v2)
    eval_args+=(
      --reasoning-effort medium
      --metadata agent_reasoning_effort=medium
      --metadata agent_prompt_mode=german_action_first
      --metadata tool_output_strategy=targeted_file_slices
    )
    ;;
  baseline-v1)
    eval_args+=(
      --metadata agent_reasoning_effort=provider_default
      --metadata agent_prompt_mode=inspect_default_plus_german
      --metadata tool_output_strategy=default_truncation
    )
    ;;
  neutral-v1)
    eval_args+=(
      --metadata agent_reasoning_effort=provider_default
      --metadata agent_prompt_mode=german_neutral_minimal
      --metadata tool_output_strategy=default_truncation
    )
    ;;
esac
if [[ -n "${eval_names}" ]]; then
  eval_args+=(-T "eval_names=${eval_names}")
fi
if [[ -n "${limit}" ]]; then
  eval_args+=(--limit "${limit}")
fi

"${uv_bin}" run inspect eval "${eval_args[@]}"
echo "Cybench log directory: ${log_dir}"

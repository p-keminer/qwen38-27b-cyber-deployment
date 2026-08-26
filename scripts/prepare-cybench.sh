#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
venv_dir="${HOME}/.local/share/qwen-eval/.venv"
cache_dir="${HOME}/.local/share/qwen-eval/inspect-evals-cache"
uv_bin="${HOME}/.local/bin/uv"
skip_images="${1:-false}"
report="${project_dir}/artifacts/benchmarks/cybench-preparation.json"

cd "${project_dir}"
"${project_dir}/scripts/check-local.sh"

export UV_PROJECT_ENVIRONMENT="${venv_dir}"
export INSPECT_EVALS_CACHE_DIR="${cache_dir}"
"${uv_bin}" sync --frozen

args=(--report "${report}")
if [[ "${skip_images}" == "true" ]]; then
  args+=(--skip-images)
fi
"${uv_bin}" run python -m scripts.prepare_cybench "${args[@]}"

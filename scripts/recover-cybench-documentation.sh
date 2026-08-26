#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
venv_dir="${HOME}/.local/share/qwen-eval/.venv"
uv_bin="${HOME}/.local/bin/uv"
execute_count="0"
dry_run_count="0"
for argument in "$@"; do
  [[ "${argument}" == "--execute" ]] && execute_count=$((execute_count + 1))
  [[ "${argument}" == "--dry-run" ]] && dry_run_count=$((dry_run_count + 1))
done
if ((execute_count + dry_run_count != 1)); then
  echo "Specify exactly one of --execute or --dry-run." >&2
  exit 2
fi

if ((execute_count == 1)); then
  [[ -n "${LLAMACPP_API_KEY:-}" ]] || {
    echo "LLAMACPP_API_KEY must be loaded outside Git for recovery execution." >&2
    exit 1
  }
  base_url="${LLAMACPP_BASE_URL:-}"
  [[ "${base_url}" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+/v1$ ]] || {
    echo "Recovery execution requires the current loopback model endpoint." >&2
    exit 1
  }
  export LLAMACPP_BASE_URL="${base_url}"
else
  # A dry run cannot accidentally authenticate or call a model even if the
  # parent shell happened to contain provider credentials.
  unset LLAMACPP_API_KEY LLAMACPP_BASE_URL || true
fi

cd "${project_dir}"
export UV_PROJECT_ENVIRONMENT="${venv_dir}"
export INSPECT_LOG_LEVEL="warning"
exec "${uv_bin}" run python -m scripts.recover_cybench_documentation "$@"

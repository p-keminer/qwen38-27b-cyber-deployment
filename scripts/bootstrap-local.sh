#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
venv_dir="${HOME}/.local/share/qwen-eval/.venv"
uv_bin="${HOME}/.local/bin/uv"

if [[ "$(id -u)" == "0" ]]; then
  echo "Run this script as the dedicated qwen-eval user, not root." >&2
  exit 1
fi

[[ -x "${uv_bin}" ]] || {
  echo "Missing ${uv_bin}; run scripts/install-uv.sh first." >&2
  exit 1
}
export UV_PROJECT_ENVIRONMENT="${venv_dir}"
cd "${project_dir}"
"${uv_bin}" sync --frozen

echo "Local Python environment is ready at ${venv_dir}."

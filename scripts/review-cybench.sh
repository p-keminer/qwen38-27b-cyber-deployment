#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
venv_dir="${HOME}/.local/share/qwen-eval/.venv"
uv_bin="${HOME}/.local/bin/uv"

cd "${project_dir}"
export UV_PROJECT_ENVIRONMENT="${venv_dir}"
exec "${uv_bin}" run python scripts/review_cybench.py "$@"

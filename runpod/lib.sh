#!/usr/bin/env bash

set -Eeuo pipefail

runpod_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "${runpod_dir}/.." && pwd)"
manifest_path="${QWEN_MODEL_MANIFEST:-${project_dir}/config/models.json}"
models_dir="${QWEN_MODELS_DIR:-${project_dir}/models}"
state_dir="${QWEN_STATE_DIR:-${project_dir}/state}"
logs_dir="${QWEN_LOGS_DIR:-${project_dir}/logs}"
cache_dir="${QWEN_CACHE_DIR:-${project_dir}/cache}"
llama_source_dir="${QWEN_LLAMA_SOURCE_DIR:-${project_dir}/runtime/llama.cpp}"
llama_server_bin="${QWEN_LLAMA_SERVER_BIN:-${llama_source_dir}/build/bin/llama-server}"

export PATH="${HOME}/.local/bin:${PATH}"
export HF_HOME="${HF_HOME:-${cache_dir}/huggingface}"

mkdir -p "${models_dir}" "${state_dir}" "${logs_dir}" "${cache_dir}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

validate_model_id() {
  [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "Invalid model id: $1"
}

model_json() {
  local model_id="$1"
  validate_model_id "${model_id}"
  jq -ce --arg id "${model_id}" '.models[] | select(.id == $id)' "${manifest_path}" \
    || die "Unknown model id: ${model_id}"
}

manifest_value() {
  jq -er "$1" "${manifest_path}"
}

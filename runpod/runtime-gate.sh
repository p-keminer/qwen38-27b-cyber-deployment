#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runpod/lib.sh
source "${script_dir}/lib.sh"

minimum_used_memory_mib="${1:?minimum used GPU memory is required}"
[[ "${minimum_used_memory_mib}" =~ ^[1-9][0-9]*$ ]]
pid_file="${state_dir}/llama-server.pid"
api_key_file="${state_dir}/api-key"
bootstrap_file="${state_dir}/bootstrap.json"
[[ -s "${pid_file}" ]] || die "llama-server PID file is missing"
[[ -s "${bootstrap_file}" ]] || die "bootstrap acceptance record is missing"
jq -e '.build_profile == "api_only_v1"' "${bootstrap_file}" >/dev/null || \
  die "bootstrap acceptance record is not the pinned API-only build profile"
pid="$(tr -dc '0-9' <"${pid_file}")"
[[ "${pid}" =~ ^[1-9][0-9]*$ ]] || die "invalid llama-server PID"
[[ -r "/proc/${pid}/cmdline" ]] || die "llama-server process argv is unavailable"
mapfile -d '' -t server_argv <"/proc/${pid}/cmdline"
(( ${#server_argv[@]} > 0 )) || die "llama-server process argv is empty"

expected_server_bin="$(readlink -f -- "${llama_server_bin}")"
actual_server_bin="$(readlink -f -- "${server_argv[0]}")"
[[ -n "${expected_server_bin}" && "${actual_server_bin}" == "${expected_server_bin}" ]] || \
  die "PID does not own the pinned llama-server binary"

require_exact_option_value() {
  local option="$1"
  local expected="$2"
  local count=0
  local index
  for ((index = 1; index < ${#server_argv[@]}; index += 1)); do
    if [[ "${server_argv[index]}" == "${option}" ]]; then
      (( index + 1 < ${#server_argv[@]} )) || die "${option} has no value"
      [[ "${server_argv[index + 1]}" == "${expected}" ]] || \
        die "${option} does not match the acceptance contract"
      count=$((count + 1))
    elif [[ "${server_argv[index]}" == "${option}="* ]]; then
      die "${option} must use the exact two-argument form"
    fi
  done
  (( count == 1 )) || die "${option} must occur exactly once"
}

require_exact_flag() {
  local flag="$1"
  local count=0
  local argument
  for argument in "${server_argv[@]:1}"; do
    if [[ "${argument}" == "${flag}" ]]; then
      count=$((count + 1))
    elif [[ "${argument}" == "${flag}="* ]]; then
      die "${flag} must use the exact flag form"
    fi
  done
  (( count == 1 )) || die "${flag} must occur exactly once"
}

require_exact_option_value --host 127.0.0.1
require_exact_option_value --api-key-file "${api_key_file}"
require_exact_option_value --n-gpu-layers 99
require_exact_option_value --ctx-size 262144
require_exact_flag --no-ui

used_memory_mib="$(
  nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits |
    awk -F, -v expected_pid="${pid}" '
      { gsub(/ /, "", $1); gsub(/ /, "", $2); if ($1 == expected_pid) print $2 }
    '
)"
[[ "${used_memory_mib}" =~ ^[0-9]+$ ]] || die "llama-server GPU allocation was not found"
(( used_memory_mib >= minimum_used_memory_mib )) || \
  die "llama-server GPU allocation is too small: ${used_memory_mib} MiB"
printf '{"schema_version":1,"process_memory_mib":%s,"server_binary_exact":true,"host_loopback_exact":true,"api_key_file_exact":true,"no_ui_exact":true,"context_size_exact":true,"api_only_build_profile_exact":true,"full_gpu_offload":true}\n' \
  "${used_memory_mib}"

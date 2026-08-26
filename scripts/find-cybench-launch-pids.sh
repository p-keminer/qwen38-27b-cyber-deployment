#!/usr/bin/env bash
set -Eeuo pipefail

expected_log_dir="${1:?expected WSL log directory is required}"
proc_root="${2:-/proc}"

[[ "${expected_log_dir}" =~ ^/mnt/[A-Za-z]/.+/artifacts/logs/[A-Za-z0-9-]+-cybench$ ]] || {
  echo "Unsafe Cybench log-directory witness." >&2
  exit 2
}
[[ -d "${proc_root}" ]] || {
  echo "Process root is not a directory." >&2
  exit 2
}

for command_file in "${proc_root}"/[1-9][0-9]*/cmdline; do
  [[ -r "${command_file}" ]] || continue
  mapfile -d '' -t argv <"${command_file}" || continue
  has_inspect_entry=false
  has_eval=false
  has_exact_log_dir=false
  for ((index = 0; index < ${#argv[@]}; index++)); do
    argument="${argv[index]}"
    [[ "${argument}" == "inspect" || "${argument}" == */inspect ]] && has_inspect_entry=true
    if (
      [[ "${argument}" == "-m" ]] &&
      ((index + 1 < ${#argv[@]})) &&
      [[ "${argv[index + 1]}" == "inspect_ai._cli.main" ]]
    ); then
      has_inspect_entry=true
    fi
    [[ "${argument}" == "eval" ]] && has_eval=true
    if (
      [[ "${argument}" == "--log-dir" ]] &&
      ((index + 1 < ${#argv[@]})) &&
      [[ "${argv[index + 1]}" == "${expected_log_dir}" ]]
    ); then
      has_exact_log_dir=true
    fi
  done
  if (
    [[ "${has_inspect_entry}" == true ]] &&
    [[ "${has_eval}" == true ]] &&
    [[ "${has_exact_log_dir}" == true ]]
  ); then
    pid="${command_file#"${proc_root}"/}"
    printf '%s\n' "${pid%/cmdline}"
  fi
done

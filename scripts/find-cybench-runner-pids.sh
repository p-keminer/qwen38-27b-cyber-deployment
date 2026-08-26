#!/usr/bin/env bash
set -Eeuo pipefail

expected_run_id="${1:?expected Cybench run id is required}"
proc_root="${2:-/proc}"

[[ "${expected_run_id}" =~ ^[A-Za-z0-9-]+$ ]] || {
  echo "Unsafe Cybench run-id witness." >&2
  exit 2
}
[[ -d "${proc_root}" ]] || {
  echo "Process root is not a directory." >&2
  exit 2
}

for command_file in "${proc_root}"/[1-9][0-9]*/cmdline; do
  [[ -r "${command_file}" ]] || continue
  mapfile -d '' -t argv <"${command_file}" || continue
  has_runner=false
  has_exact_run_id=false
  if (
    ((${#argv[@]} >= 2)) &&
    [[ "${argv[0]}" == "bash" || "${argv[0]}" == */bash ]] &&
    [[ "${argv[1]}" == "scripts/run-cybench.sh" || "${argv[1]}" == */run-cybench.sh ]]
  ); then
    has_runner=true
  fi
  for ((index = 0; index < ${#argv[@]}; index++)); do
    argument="${argv[index]}"
    if (
      [[ "${argument}" == "--run-id" ]] &&
      ((index + 1 < ${#argv[@]})) &&
      [[ "${argv[index + 1]}" == "${expected_run_id}" ]]
    ); then
      has_exact_run_id=true
    fi
  done
  if [[ "${has_runner}" == true && "${has_exact_run_id}" == true ]]; then
    pid="${command_file#"${proc_root}"/}"
    printf '%s\n' "${pid%/cmdline}"
  fi
done

#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
venv_dir="${HOME}/.local/share/qwen-eval/.venv"
uv_bin="${HOME}/.local/bin/uv"
log_dir="${project_dir}/artifacts/logs"
state_dir="${HOME}/.local/share/qwen-eval/inspect-view"
pid_file="${state_dir}/viewer.pid"
viewer_log="${state_dir}/viewer.log"
lock_file="${state_dir}/lifecycle.lock"

action="${1:-start}"
case "${action}" in
  start|status|stop)
    port="${2:-7575}"
    ;;
  [0-9]*)
    # Backwards compatibility for the former `view-cybench.sh PORT` form.
    port="${action}"
    action="start"
    ;;
  *)
    echo "Usage: view-cybench.sh {start|status|stop} [PORT]" >&2
    exit 2
    ;;
esac

if [[ ! "${port}" =~ ^[0-9]+$ ]] || ((1024 > 10#${port} || 10#${port} > 65535)); then
  echo "Invalid viewer port: ${port}" >&2
  exit 2
fi

export UV_PROJECT_ENVIRONMENT="${venv_dir}"
install -d -m 0700 "${state_dir}"
exec 9>"${lock_file}"
if ! flock --exclusive --wait 20 9; then
  echo "Another Inspect View lifecycle action is still in progress." >&2
  exit 2
fi

expected_command=(
  "${uv_bin}"
  run
  inspect
  view
  start
  --host
  127.0.0.1
  --port
  "${port}"
  --log-dir
  "${log_dir}"
  --display
  none
)
expected_child_command=(
  "${venv_dir}/bin/python"
  "${venv_dir}/bin/inspect"
  view
  start
  --host
  127.0.0.1
  --port
  "${port}"
  --log-dir
  "${log_dir}"
  --display
  none
)

owned_process() {
  local pid="$1"
  local index
  local -a actual_command=()
  [[ "${pid}" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/cmdline" ]] || return 1
  mapfile -d '' -t actual_command <"/proc/${pid}/cmdline" || return 1
  ((${#actual_command[@]} == ${#expected_command[@]})) || return 1
  for ((index = 0; index < ${#expected_command[@]}; index++)); do
    [[ "${actual_command[index]}" == "${expected_command[index]}" ]] || return 1
  done
}

inspect_child_command_matches() {
  local pid="$1"
  local index
  local -a actual_command=()
  [[ "${pid}" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/cmdline" ]] || return 1
  mapfile -d '' -t actual_command <"/proc/${pid}/cmdline" || return 1
  ((${#actual_command[@]} == ${#expected_child_command[@]})) || return 1
  for ((index = 0; index < ${#expected_child_command[@]}; index++)); do
    [[ "${actual_command[index]}" == "${expected_child_command[index]}" ]] || return 1
  done
}

find_owned_child_pids() {
  local parent_pid="$1" process_path pid parent
  for process_path in /proc/[1-9][0-9]*/cmdline; do
    [[ -r "${process_path}" ]] || continue
    pid="${process_path#/proc/}"
    pid="${pid%/cmdline}"
    inspect_child_command_matches "${pid}" || continue
    parent="$(ps -o ppid= -p "${pid}" | tr -d '[:space:]')"
    if [[ "${parent}" == "${parent_pid}" ]]; then
      printf '%s\n' "${pid}"
    fi
  done
}

find_owned_pids() {
  local process_path pid
  for process_path in /proc/[1-9][0-9]*/cmdline; do
    [[ -r "${process_path}" ]] || continue
    pid="${process_path#/proc/}"
    pid="${pid%/cmdline}"
    if owned_process "${pid}"; then
      printf '%s\n' "${pid}"
    fi
  done
}

find_matching_child_pids() {
  local process_path pid
  for process_path in /proc/[1-9][0-9]*/cmdline; do
    [[ -r "${process_path}" ]] || continue
    pid="${process_path#/proc/}"
    pid="${pid%/cmdline}"
    if inspect_child_command_matches "${pid}"; then
      printf '%s\n' "${pid}"
    fi
  done
}

endpoint_ready() {
  local response
  response="$(
    curl --fail --silent --show-error --max-time 3 \
      "http://127.0.0.1:${port}/" 2>/dev/null
  )" || return 1
  [[ "${response}" == *Inspect* ]]
}

write_pid_file() {
  local pid="$1" temporary
  install -d -m 0700 "${state_dir}"
  temporary="${pid_file}.$$.tmp"
  printf '%s\n' "${pid}" >"${temporary}"
  mv -f -- "${temporary}" "${pid_file}"
}

stop_owned_process() {
  local pid="$1" session_id child_pid still_running
  local -a child_pids=()
  owned_process "${pid}" || return 0
  mapfile -t child_pids < <(find_owned_child_pids "${pid}")
  session_id="$(ps -o sid= -p "${pid}" | tr -d '[:space:]')"
  if [[ "${session_id}" == "${pid}" ]]; then
    kill -TERM -- "-${pid}" 2>/dev/null || true
  else
    for child_pid in "${child_pids[@]}"; do
      if inspect_child_command_matches "${child_pid}"; then
        kill -TERM "${child_pid}" 2>/dev/null || true
      fi
    done
    kill -TERM "${pid}" 2>/dev/null || true
  fi
  for _ in $(seq 1 50); do
    still_running="false"
    if owned_process "${pid}"; then
      still_running="true"
    fi
    for child_pid in "${child_pids[@]}"; do
      if inspect_child_command_matches "${child_pid}"; then
        still_running="true"
      fi
    done
    [[ "${still_running}" == "true" ]] || return 0
    sleep 0.1
  done
  if owned_process "${pid}"; then
    if [[ "${session_id}" == "${pid}" ]]; then
      kill -KILL -- "-${pid}" 2>/dev/null || true
    else
      kill -KILL "${pid}" 2>/dev/null || true
    fi
  fi
  for child_pid in "${child_pids[@]}"; do
    if inspect_child_command_matches "${child_pid}"; then
      kill -KILL "${child_pid}" 2>/dev/null || true
    fi
  done
  sleep 0.1
  if owned_process "${pid}"; then
    echo "Project-owned Inspect View process ${pid} did not stop." >&2
    return 1
  fi
  for child_pid in "${child_pids[@]}"; do
    if inspect_child_command_matches "${child_pid}"; then
      echo "Project-owned Inspect View child ${child_pid} did not stop." >&2
      return 1
    fi
  done
}

stop_orphan_child() {
  local pid="$1"
  inspect_child_command_matches "${pid}" || return 0
  kill -TERM "${pid}" 2>/dev/null || true
  for _ in $(seq 1 50); do
    inspect_child_command_matches "${pid}" || return 0
    sleep 0.1
  done
  if inspect_child_command_matches "${pid}"; then
    kill -KILL "${pid}" 2>/dev/null || true
  fi
  sleep 0.1
  if inspect_child_command_matches "${pid}"; then
    echo "Project-owned orphan Inspect View child ${pid} did not stop." >&2
    return 1
  fi
}

mapfile -t owned_pids < <(find_owned_pids)
mapfile -t matching_child_pids < <(find_matching_child_pids)
if ((${#owned_pids[@]} > 1 || ${#matching_child_pids[@]} > 1)); then
  echo "Refusing ambiguous Inspect View ownership: ${#owned_pids[@]} launcher(s), ${#matching_child_pids[@]} child process(es)." >&2
  exit 2
fi

owned_pid=""
owned_kind=""
if ((${#owned_pids[@]} == 1)); then
  if ((${#matching_child_pids[@]} == 1)); then
    child_parent="$(ps -o ppid= -p "${matching_child_pids[0]}" | tr -d '[:space:]')"
    if [[ "${child_parent}" != "${owned_pids[0]}" ]]; then
      echo "Refusing an Inspect View launcher with an unrelated matching child." >&2
      exit 2
    fi
  fi
  owned_pid="${owned_pids[0]}"
  owned_kind="launcher"
elif ((${#matching_child_pids[@]} == 1)); then
  # A legacy uv launcher can exit while its exact Inspect child survives. The
  # full interpreter, command, project log directory and port still bind this
  # orphan narrowly enough for safe status and teardown.
  owned_pid="${matching_child_pids[0]}"
  owned_kind="orphan_child"
fi

case "${action}" in
  status)
    if [[ -n "${owned_pid}" ]] && endpoint_ready; then
      echo "Project-owned Inspect View is ready on 127.0.0.1:${port} (WSL PID ${owned_pid}, ${owned_kind})."
      exit 0
    fi
    exit 1
    ;;
  start)
    if [[ -n "${owned_pid}" ]]; then
      if endpoint_ready; then
        write_pid_file "${owned_pid}"
        echo "Project-owned Inspect View already ready on 127.0.0.1:${port} (WSL PID ${owned_pid}, ${owned_kind})."
        exit 0
      fi
      echo "A project-owned Inspect View process exists but its endpoint is not ready." >&2
      exit 1
    fi

    install -d -m 0700 "${state_dir}"
    rm -f -- "${pid_file}"
    if ss -H -ltn "sport = :${port}" | grep -q .; then
      echo "Viewer port ${port} is occupied by a process not owned by this project." >&2
      exit 1
    fi

    : >"${viewer_log}"
    nohup setsid "${expected_command[@]}" >"${viewer_log}" 2>&1 </dev/null &
    viewer_pid=$!
    write_pid_file "${viewer_pid}"
    for _ in $(seq 1 60); do
      if ! owned_process "${viewer_pid}"; then
        break
      fi
      if endpoint_ready; then
        echo "Inspect View ready on 127.0.0.1:${port} (WSL PID ${viewer_pid})."
        exit 0
      fi
      sleep 0.25
    done

    if owned_process "${viewer_pid}"; then
      stop_owned_process "${viewer_pid}"
    fi
    mapfile -t leftover_children < <(find_matching_child_pids)
    if ((${#leftover_children[@]} == 1)); then
      stop_orphan_child "${leftover_children[0]}"
    elif ((${#leftover_children[@]} > 1)); then
      echo "Refusing ambiguous leftover Inspect View children." >&2
    fi
    rm -f -- "${pid_file}"
    tail -n 40 "${viewer_log}" >&2 || true
    echo "Inspect View did not become ready on 127.0.0.1:${port}." >&2
    exit 1
    ;;
  stop)
    if [[ "${owned_kind}" == "launcher" ]]; then
      stop_owned_process "${owned_pid}"
      echo "Project-owned Inspect View stopped (WSL PID ${owned_pid})."
    elif [[ "${owned_kind}" == "orphan_child" ]]; then
      stop_orphan_child "${owned_pid}"
      echo "Project-owned orphan Inspect View child stopped (WSL PID ${owned_pid})."
    else
      echo "No project-owned Inspect View process is running on port ${port}."
    fi
    rm -f -- "${pid_file}"
    ;;
esac

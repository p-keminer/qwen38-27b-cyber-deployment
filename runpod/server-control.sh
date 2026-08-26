#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runpod/lib.sh
source "${script_dir}/lib.sh"

pid_file="${state_dir}/llama-server.pid"
current_file="${state_dir}/current-server.json"
api_key_file="${state_dir}/api-key"
server_port="$(manifest_value '.llama_cpp.server_port')"

usage() {
  cat <<'EOF'
Usage:
  server-control.sh start MODEL_ID
  server-control.sh restart MODEL_ID
  server-control.sh stop
  server-control.sh status
  server-control.sh logs [LINES]
EOF
}

server_pid() {
  if [[ -s "${pid_file}" ]]; then
    tr -dc '0-9' <"${pid_file}"
  fi
}

server_is_running() {
  local pid command_line
  pid="$(server_pid)"
  [[ -n "${pid}" ]] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  command_line="$(ps -p "${pid}" -o args= 2>/dev/null || true)"
  [[ "${command_line}" == *"${llama_server_bin}"* ]]
}

stop_server() {
  local pid
  if ! server_is_running; then
    rm -f "${pid_file}"
    echo "llama-server is not running."
    return 0
  fi
  pid="$(server_pid)"
  kill -TERM "${pid}"
  for _ in $(seq 1 60); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "${pid}" 2>/dev/null; then
    kill -KILL "${pid}"
  fi
  rm -f "${pid_file}"
  echo "llama-server stopped."
}

start_server() {
  local model_id="$1"
  local record model_path projector_path alias context_size run_id log_file pid api_key
  local -a command

  require_command curl
  require_command jq
  require_command nvidia-smi
  [[ -x "${llama_server_bin}" ]] || die "llama-server is missing; run runpod/bootstrap.sh first"
  [[ -s "${api_key_file}" ]] || die "${api_key_file} is missing"
  chmod 600 "${api_key_file}"

  # download performs a full size and SHA-256 verification even when the
  # files already exist; do not hash the 22+ GB payload a second time.
  "${script_dir}/modelctl.sh" download "${model_id}"
  record="$(model_json "${model_id}")"
  model_path="$("${script_dir}/modelctl.sh" path "${model_id}")"
  projector_path="$("${script_dir}/modelctl.sh" mmproj "${model_id}")"
  alias="$(jq -er '.alias' <<<"${record}")"
  context_size="${QWEN_CTX_SIZE:-$(jq -er '.context_size' <<<"${record}")}"
  [[ "${context_size}" =~ ^[0-9]+$ ]] || die "Invalid context size: ${context_size}"
  (( context_size >= 4096 && context_size <= 262144 )) || die "Context size out of range: ${context_size}"

  stop_server
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  log_file="${logs_dir}/llama-${model_id}-${run_id}.log"
  command=(
    "${llama_server_bin}"
    --model "${model_path}"
    --mmproj "${projector_path}"
    --alias "${alias}"
    --host 127.0.0.1
    --port "${server_port}"
    --ctx-size "${context_size}"
    --n-gpu-layers 99
    --flash-attn on
    --jinja
    --no-agent
    --no-ui
    --parallel 1
    --no-cont-batching
    --cache-prompt
    --sampling-seq k
    --top-k 1
    --metrics
    --api-key-file "${api_key_file}"
  )

  printf 'Starting %s on pod loopback port %s\n' "${model_id}" "${server_port}"
  nohup "${command[@]}" >"${log_file}" 2>&1 </dev/null &
  pid="$!"
  printf '%s\n' "${pid}" >"${pid_file}"

  for _ in $(seq 1 900); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      tail -n 100 "${log_file}" >&2 || true
      die "llama-server exited before becoming ready"
    fi
    if curl --fail --silent --max-time 2 "http://127.0.0.1:${server_port}/health" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  curl --fail --silent --max-time 5 "http://127.0.0.1:${server_port}/health" >/dev/null \
    || die "llama-server did not become ready within 15 minutes"
  api_key="$(<"${api_key_file}")"
  curl --fail --silent --max-time 10 \
    --header "Authorization: Bearer ${api_key}" \
    "http://127.0.0.1:${server_port}/v1/models" >/dev/null

  jq -n \
    --arg model_id "${model_id}" \
    --arg alias "${alias}" \
    --arg model_path "${model_path}" \
    --arg projector_path "${projector_path}" \
    --arg log_file "${log_file}" \
    --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson pid "${pid}" \
    --argjson port "${server_port}" \
    --argjson context_size "${context_size}" \
    '{model_id:$model_id,alias:$alias,model_path:$model_path,projector_path:$projector_path,pid:$pid,port:$port,context_size:$context_size,log_file:$log_file,started_at:$started_at}' \
    >"${current_file}"
  echo "llama-server ready: ${alias}"
  echo "Remote endpoint: http://127.0.0.1:${server_port}/v1"
  echo "Log: ${log_file}"
}

status_server() {
  local api_key
  if ! server_is_running; then
    echo '{"running":false}'
    return 0
  fi
  api_key="$(<"${api_key_file}")"
  jq -c '. + {running:true}' "${current_file}"
  curl --fail --silent --max-time 5 "http://127.0.0.1:${server_port}/health"
  curl --fail --silent --max-time 5 \
    --header "Authorization: Bearer ${api_key}" \
    "http://127.0.0.1:${server_port}/v1/models"
}

case "${1:-}" in
  start)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    start_server "$2"
    ;;
  restart)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    start_server "$2"
    ;;
  stop)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    stop_server
    ;;
  status)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    status_server
    ;;
  logs)
    lines="${2:-100}"
    [[ "${lines}" =~ ^[0-9]+$ ]] || die "Invalid line count: ${lines}"
    [[ -s "${current_file}" ]] || die "No server metadata found"
    tail -n "${lines}" "$(jq -er '.log_file' "${current_file}")"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

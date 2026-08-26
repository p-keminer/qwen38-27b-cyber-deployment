#!/usr/bin/env bash
set -Eeuo pipefail

action="${1:?action is required}"
state_dir="${HOME}/.local/share/qwen-eval/runpod-tunnel"
pid_file="${state_dir}/tunnel.pid"
identity_file="${state_dir}/identity"
known_hosts_file="${state_dir}/known_hosts"
log_file="${state_dir}/tunnel.log"

validate_host() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] || {
    echo "Invalid SSH host: $1" >&2
    exit 2
  }
}

validate_user() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || {
    echo "Invalid SSH user: $1" >&2
    exit 2
  }
}

validate_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535)) || {
    echo "Invalid port: $1" >&2
    exit 2
  }
}

owned_process() {
  local pid="$1"
  local forward="$2"
  local destination="$3"
  [[ "${pid}" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/cmdline" ]] || return 1
  local command_line
  command_line="$(tr '\0' ' ' <"/proc/${pid}/cmdline")"
  [[ "${command_line}" == *"ssh"* \
    && "${command_line}" == *"${forward}"* \
    && "${command_line}" == *"${destination}"* ]]
}

case "${action}" in
  start)
    ssh_host="${2:?SSH host is required}"
    ssh_port="${3:?SSH port is required}"
    ssh_user="${4:?SSH user is required}"
    identity_source="${5:?identity source is required}"
    known_hosts_source="${6:?known-hosts source is required}"
    local_port="${7:?local port is required}"
    remote_port="${8:?remote port is required}"
    validate_host "${ssh_host}"
    validate_port "${ssh_port}"
    validate_user "${ssh_user}"
    validate_port "${local_port}"
    validate_port "${remote_port}"
    [[ -f "${identity_source}" ]] || {
      echo "WSL cannot read the Windows SSH identity: ${identity_source}" >&2
      exit 1
    }
    [[ -f "${known_hosts_source}" ]] || {
      echo "WSL cannot read the Windows known_hosts file: ${known_hosts_source}" >&2
      exit 1
    }

    install -d -m 0700 "${state_dir}"
    install -m 0600 "${identity_source}" "${identity_file}"
    install -m 0600 "${known_hosts_source}" "${known_hosts_file}"
    forward="127.0.0.1:${local_port}:127.0.0.1:${remote_port}"
    destination="${ssh_user}@${ssh_host}"

    if [[ -f "${pid_file}" ]]; then
      existing_pid="$(<"${pid_file}")"
      if owned_process "${existing_pid}" "${forward}" "${destination}"; then
        if curl --fail --silent --show-error --max-time 5 \
          "http://127.0.0.1:${local_port}/health" >/dev/null; then
          echo "WSL RunPod tunnel already ready on 127.0.0.1:${local_port}."
          exit 0
        fi
        kill "${existing_pid}"
        wait "${existing_pid}" 2>/dev/null || true
      elif kill -0 "${existing_pid}" 2>/dev/null; then
        echo "Refusing to replace unexpected process from ${pid_file}." >&2
        exit 1
      fi
      rm -f -- "${pid_file}"
    fi

    if ss -H -ltn "sport = :${local_port}" | grep -q .; then
      echo "WSL port ${local_port} is already occupied by another process." >&2
      exit 1
    fi

    : >"${log_file}"
    nohup ssh -N -T \
      -p "${ssh_port}" \
      -i "${identity_file}" \
      -o BatchMode=yes \
      -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=yes \
      -o "UserKnownHostsFile=${known_hosts_file}" \
      -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      -L "${forward}" \
      "${destination}" >"${log_file}" 2>&1 </dev/null &
    tunnel_pid=$!
    printf '%s\n' "${tunnel_pid}" >"${pid_file}"

    for _ in $(seq 1 60); do
      if ! kill -0 "${tunnel_pid}" 2>/dev/null; then
        break
      fi
      if curl --fail --silent --show-error --max-time 3 \
        "http://127.0.0.1:${local_port}/health" >/dev/null; then
        echo "WSL RunPod tunnel ready on 127.0.0.1:${local_port} (PID ${tunnel_pid})."
        exit 0
      fi
      sleep 0.5
    done

    if owned_process "${tunnel_pid}" "${forward}" "${destination}"; then
      kill "${tunnel_pid}" 2>/dev/null || true
    fi
    rm -f -- "${pid_file}"
    tail -n 20 "${log_file}" >&2 || true
    echo "WSL RunPod tunnel did not become ready." >&2
    exit 1
    ;;
  stop)
    ssh_host="${2:?SSH host is required}"
    ssh_user="${3:?SSH user is required}"
    local_port="${4:?local port is required}"
    remote_port="${5:?remote port is required}"
    validate_host "${ssh_host}"
    validate_user "${ssh_user}"
    validate_port "${local_port}"
    validate_port "${remote_port}"
    forward="127.0.0.1:${local_port}:127.0.0.1:${remote_port}"
    destination="${ssh_user}@${ssh_host}"

    if [[ -f "${pid_file}" ]]; then
      existing_pid="$(<"${pid_file}")"
      if owned_process "${existing_pid}" "${forward}" "${destination}"; then
        kill "${existing_pid}"
        for _ in $(seq 1 20); do
          kill -0 "${existing_pid}" 2>/dev/null || break
          sleep 0.1
        done
      elif kill -0 "${existing_pid}" 2>/dev/null; then
        echo "Refusing to stop unexpected process from ${pid_file}." >&2
        exit 1
      fi
    fi
    rm -f -- "${pid_file}" "${identity_file}" "${known_hosts_file}"
    echo "WSL RunPod tunnel stopped."
    ;;
  *)
    echo "Unknown action: ${action}" >&2
    exit 2
    ;;
esac

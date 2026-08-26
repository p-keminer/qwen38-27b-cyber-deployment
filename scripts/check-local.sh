#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
expected_user="qwen-eval"

cd "${project_dir}"

[[ "$(whoami)" == "${expected_user}" ]] || {
  echo "Expected WSL user ${expected_user}; got $(whoami)." >&2
  exit 1
}

if id -nG | tr ' ' '\n' | grep -Fxq sudo; then
  echo "The controller user must not be in the sudo group." >&2
  exit 1
fi

[[ "$(command -v docker)" == "/usr/bin/docker" ]] || {
  echo "Docker Desktop WSL integration is not active." >&2
  exit 1
}

docker info >/dev/null
docker compose version >/dev/null
test -S /var/run/docker.sock
test ! -e /usr/bin/dockerd

echo "Local controller checks passed."
echo "user=$(whoami)"
echo "docker=$(docker version --format '{{.Client.Version}}/{{.Server.Version}}')"
echo "compose=$(docker compose version --short)"

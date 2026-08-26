#!/usr/bin/env bash
set -Eeuo pipefail

uv_version="0.12.5"
uv_expected_hash="68a509da24b06b4223a1c0175fb5eb5bc79342b76cbeff0cfe51ac3f5b17b6b2"
uv_tmp_dir="$(mktemp -d)"
uv_archive="${uv_tmp_dir}/uv.tar.gz"

cleanup() {
  case "${uv_tmp_dir}" in
    /tmp/tmp.*) rm -rf -- "${uv_tmp_dir}" ;;
    *) echo "Refusing to remove unexpected temporary path: ${uv_tmp_dir}" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

if [[ "$(id -u)" == "0" ]]; then
  echo "Install uv as the dedicated qwen-eval user, not root." >&2
  exit 1
fi

curl --fail --location --proto '=https' --tlsv1.2 \
  --output "${uv_archive}" \
  "https://github.com/astral-sh/uv/releases/download/${uv_version}/uv-x86_64-unknown-linux-gnu.tar.gz"

uv_actual_hash="$(sha256sum "${uv_archive}" | awk '{print $1}')"
if [[ "${uv_actual_hash}" != "${uv_expected_hash}" ]]; then
  echo "uv archive hash mismatch" >&2
  exit 1
fi

tar -xzf "${uv_archive}" -C "${uv_tmp_dir}"
install -Dm755 \
  "${uv_tmp_dir}/uv-x86_64-unknown-linux-gnu/uv" \
  "${HOME}/.local/bin/uv"
install -Dm755 \
  "${uv_tmp_dir}/uv-x86_64-unknown-linux-gnu/uvx" \
  "${HOME}/.local/bin/uvx"

"${HOME}/.local/bin/uv" --version

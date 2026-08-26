#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runpod/lib.sh
source "${script_dir}/lib.sh"

selected_model=""
download_all="false"
skip_start="false"
model_source="prefer-local"

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [--model MODEL_ID] [--download-all] [--skip-start]
                    [--model-source hub|prefer-local|local-only]

Idempotently prepares an Ubuntu/CUDA RunPod, builds pinned llama.cpp,
downloads the pinned GGUF files, and starts one loopback-only model server.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      [[ $# -ge 2 ]] || die "--model requires a value"
      selected_model="$2"
      shift 2
      ;;
    --download-all)
      download_all="true"
      shift
      ;;
    --skip-start)
      skip_start="true"
      shift
      ;;
    --model-source)
      [[ $# -ge 2 ]] || die "--model-source requires a value"
      model_source="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -r "${manifest_path}" ]] || die "Missing model manifest: ${manifest_path}"
[[ "$(id -u)" == "0" ]] || die "RunPod bootstrap must run as root in the official Pod template"
command -v apt-get >/dev/null 2>&1 || die "This workflow expects an Ubuntu/Debian RunPod template"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  cmake \
  curl \
  git \
  jq \
  ninja-build \
  openssl \
  pkg-config \
  procps \
  python3 \
  python3-pip \
  util-linux

require_command nvidia-smi

# RunPod's official CUDA development images contain nvcc below
# /usr/local/cuda/bin, but non-login SSH commands do not always inherit that
# directory in PATH. Discover the toolkit before treating the image as
# runtime-only so the same bootstrap works over direct SSH and interactively.
if ! command -v nvcc >/dev/null 2>&1; then
  for cuda_bin in /usr/local/cuda/bin /usr/local/cuda-*/bin; do
    if [[ -x "${cuda_bin}/nvcc" ]]; then
      export PATH="${cuda_bin}:${PATH}"
      break
    fi
  done
fi
require_command nvcc
nvidia-smi >/dev/null
if [[ -z "${selected_model}" ]]; then
  selected_model="$(manifest_value '.default_model_id')"
fi
model_json "${selected_model}" >/dev/null

case "${model_source}" in
  hub|prefer-local|local-only) ;;
  *) die "Unsupported model source: ${model_source}" ;;
esac
export QWEN_MODEL_SOURCE="${model_source}"

hf_cli_version="1.28.0"
if [[ "${model_source}" != "local-only" ]]; then
  hf_installed_version="$(python3 -c 'import huggingface_hub; print(huggingface_hub.__version__)' 2>/dev/null || true)"
  if [[ "${hf_installed_version}" != "${hf_cli_version}" ]]; then
    python3 -m pip install \
      --disable-pip-version-check \
      --no-cache-dir \
      "huggingface_hub==${hf_cli_version}"
  fi
  require_command hf
  [[ "$(python3 -c 'import huggingface_hub; print(huggingface_hub.__version__)')" == "${hf_cli_version}" ]] || \
    die "Unexpected Hugging Face CLI version"
  hf version
fi

if [[ ! -s "${state_dir}/api-key" ]]; then
  umask 077
  openssl rand -hex 32 >"${state_dir}/api-key"
  echo "Generated ${state_dir}/api-key; copy it only through SSH/SCP."
fi
chmod 600 "${state_dir}/api-key"

llama_repo="$(manifest_value '.llama_cpp.repository')"
llama_revision="$(manifest_value '.llama_cpp.revision')"
llama_expected_commit_prefix="$(manifest_value '.llama_cpp.expected_commit_prefix')"
mkdir -p "$(dirname -- "${llama_source_dir}")"
if [[ ! -d "${llama_source_dir}/.git" ]]; then
  git clone --filter=blob:none "${llama_repo}" "${llama_source_dir}"
fi
git -C "${llama_source_dir}" fetch --force --depth 1 origin "refs/tags/${llama_revision}:refs/tags/${llama_revision}"
git -C "${llama_source_dir}" checkout --detach "${llama_revision}"
llama_resolved_revision="$(git -C "${llama_source_dir}" rev-parse HEAD)"
[[ "${llama_resolved_revision}" == "${llama_expected_commit_prefix}"* ]] || \
  die "llama.cpp ${llama_revision} resolved to unexpected commit ${llama_resolved_revision}"
cuda_architectures="$(
  nvidia-smi --query-gpu=compute_cap --format=csv,noheader |
    tr -d '.' |
    sort -u |
    paste -sd ';' -
)"
[[ "${cuda_architectures}" =~ ^[0-9]+(\;[0-9]+)*$ ]] || \
  die "Could not determine CUDA compute capabilities from nvidia-smi"

build_jobs="${QWEN_BUILD_JOBS:-}"
if [[ -z "${build_jobs}" ]]; then
  build_jobs="$(nproc)"
  cpu_quota=""
  cpu_period=""
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    read -r cpu_quota cpu_period </sys/fs/cgroup/cpu.max
  elif [[ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us && -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]]; then
    cpu_quota="$(</sys/fs/cgroup/cpu/cpu.cfs_quota_us)"
    cpu_period="$(</sys/fs/cgroup/cpu/cpu.cfs_period_us)"
  fi
  if [[ "${cpu_quota}" =~ ^[0-9]+$ && "${cpu_period}" =~ ^[0-9]+$ ]] &&
     (( cpu_quota > 0 && cpu_period > 0 )); then
    quota_jobs=$(((cpu_quota + cpu_period - 1) / cpu_period))
    if (( quota_jobs < build_jobs )); then
      build_jobs="${quota_jobs}"
    fi
  fi
fi
[[ "${build_jobs}" =~ ^[1-9][0-9]*$ ]] || die "Invalid QWEN_BUILD_JOBS value: ${build_jobs}"

printf 'Building llama.cpp for CUDA architecture(s) %s with %s parallel job(s).\n' \
  "${cuda_architectures}" "${build_jobs}"
ui_build_dir="${llama_source_dir}/build/tools/ui"
# The pinned upstream UI provisioner falls back from its build-number bucket to
# the mutable "latest" bucket. Remove any assets left by an earlier configure or
# build so an API-only rebuild cannot silently embed that fallback.
rm -rf -- "${ui_build_dir}/dist" "${ui_build_dir}/ui-src"
rm -f -- \
  "${ui_build_dir}/.ui-stamp" \
  "${ui_build_dir}/dist.tar.gz" \
  "${ui_build_dir}/dist.tar.gz.sha256" \
  "${ui_build_dir}/ui.cpp" \
  "${ui_build_dir}/ui.h"
cmake -S "${llama_source_dir}" -B "${llama_source_dir}/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_ARCHITECTURES="${cuda_architectures}" \
  -DGGML_CUDA=ON \
  -DLLAMA_BUILD_UI=OFF \
  -DLLAMA_USE_PREBUILT_UI=OFF \
  -DLLAMA_CURL=OFF
cmake --build "${llama_source_dir}/build" --config Release --target llama-server \
  --parallel "${build_jobs}"
[[ -x "${llama_server_bin}" ]] || die "llama-server build did not produce ${llama_server_bin}"
grep -Eq '^CMAKE_CUDA_ARCHITECTURES:[^=]+=80$' "${llama_source_dir}/build/CMakeCache.txt" || \
  die "A100 deployment requires CMAKE_CUDA_ARCHITECTURES=80"
grep -Eq '^GGML_CUDA:BOOL=ON$' "${llama_source_dir}/build/CMakeCache.txt" || \
  die "llama.cpp was not configured with GGML_CUDA=ON"
grep -Eq '^LLAMA_BUILD_UI:BOOL=OFF$' "${llama_source_dir}/build/CMakeCache.txt" || \
  die "llama.cpp was not configured with LLAMA_BUILD_UI=OFF"
grep -Eq '^LLAMA_USE_PREBUILT_UI:BOOL=OFF$' "${llama_source_dir}/build/CMakeCache.txt" || \
  die "llama.cpp was not configured with LLAMA_USE_PREBUILT_UI=OFF"
ui_header="${ui_build_dir}/ui.h"
[[ -f "${ui_header}" ]] || die "llama.cpp did not generate its API-only UI shim"
if grep -Eq '^[[:space:]]*#[[:space:]]*define[[:space:]]+LLAMA_UI_HAS_ASSETS([[:space:]]|$)' "${ui_header}"; then
  die "llama.cpp embedded Web UI assets in the API-only build"
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)"
{
  date -u
  uname -a
  nvidia-smi
  nvcc --version
  if command -v hf >/dev/null 2>&1; then hf version; else printf 'hf: intentionally omitted (local-only)\n'; fi
  printf 'llama.cpp revision: %s\n' "$(git -C "${llama_source_dir}" rev-parse HEAD)"
  df -h "${project_dir}"
  free -h
} >"${logs_dir}/bootstrap-${run_id}.log" 2>&1

if [[ "${download_all}" == "true" ]]; then
  "${script_dir}/modelctl.sh" download-all
elif [[ "${skip_start}" == "true" ]]; then
  # A normal bootstrap lets server-control download and hash the selected
  # model exactly once immediately before launch. A build-only bootstrap
  # still materializes and verifies the requested artifact here.
  "${script_dir}/modelctl.sh" download "${selected_model}"
fi

jq -n \
  --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg build_profile "api_only_v1" \
  --arg selected_model "${selected_model}" \
  --arg model_source "${model_source}" \
  --arg llama_cpp_revision "${llama_resolved_revision}" \
  --arg cuda_architectures "${cuda_architectures}" \
  --arg log_file "${logs_dir}/bootstrap-${run_id}.log" \
  '{completed_at:$completed_at,build_profile:$build_profile,selected_model:$selected_model,model_source:$model_source,llama_cpp_revision:$llama_cpp_revision,cuda_architectures:$cuda_architectures,log_file:$log_file}' \
  >"${state_dir}/bootstrap.json"

if [[ "${skip_start}" == "false" ]]; then
  "${script_dir}/server-control.sh" start "${selected_model}"
fi

echo "RunPod preparation completed."

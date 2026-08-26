#!/usr/bin/env bash
set -Eeuo pipefail

expected_gpu_name="${1:?expected GPU name is required}"
expected_compute_capability="${2:?expected compute capability is required}"
expected_cuda_release="${3:?expected CUDA release is required}"
minimum_memory_mib="${4:?minimum GPU memory is required}"
minimum_workspace_bytes="${5:?minimum workspace bytes is required}"
state_path="${6:?state path is required}"

[[ ! "${expected_gpu_name}" =~ [^A-Za-z0-9._[:space:]-] ]]
[[ "${expected_compute_capability}" =~ ^[0-9]+\.[0-9]+$ ]]
[[ "${expected_cuda_release}" =~ ^[0-9]+\.[0-9]+$ ]]
[[ "${minimum_memory_mib}" =~ ^[1-9][0-9]*$ ]]
[[ "${minimum_workspace_bytes}" =~ ^[1-9][0-9]*$ ]]
command -v nvidia-smi >/dev/null 2>&1

mapfile -t gpu_rows < <(nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader,nounits)
(( ${#gpu_rows[@]} == 1 )) || {
  echo "Expected exactly one GPU, found ${#gpu_rows[@]}" >&2
  exit 1
}
IFS=',' read -r gpu_name gpu_memory_mib compute_capability <<<"${gpu_rows[0]}"
gpu_name="$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"${gpu_name}")"
gpu_memory_mib="$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"${gpu_memory_mib}")"
compute_capability="$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"${compute_capability}")"
[[ "${gpu_name}" == "${expected_gpu_name}" ]] || {
  echo "Unexpected GPU: ${gpu_name}" >&2
  exit 1
}
[[ "${compute_capability}" == "${expected_compute_capability}" ]] || {
  echo "Unexpected compute capability: ${compute_capability}" >&2
  exit 1
}
if [[ ! "${gpu_memory_mib}" =~ ^[0-9]+$ ]] || (( gpu_memory_mib < minimum_memory_mib )); then
  echo "Insufficient GPU memory: ${gpu_memory_mib} MiB" >&2
  exit 1
fi

nvcc_bin="$(command -v nvcc || true)"
if [[ -z "${nvcc_bin}" ]]; then
  for candidate in /usr/local/cuda/bin/nvcc /usr/local/cuda-*/bin/nvcc; do
    if [[ -x "${candidate}" ]]; then
      nvcc_bin="${candidate}"
      break
    fi
  done
fi
[[ -x "${nvcc_bin}" ]] || { echo "nvcc is missing" >&2; exit 1; }
cuda_release="$(${nvcc_bin} --version | sed -nE 's/.*release ([0-9]+\.[0-9]+).*/\1/p' | tail -n 1)"
[[ "${cuda_release}" == "${expected_cuda_release}" ]] || {
  echo "Unexpected CUDA toolkit release: ${cuda_release}" >&2
  exit 1
}

[[ -d /workspace && -w /workspace ]] || { echo "/workspace is not writable" >&2; exit 1; }
mount_target="$(findmnt -n -o TARGET -T /workspace)"
[[ "${mount_target}" == "/workspace" ]] || {
  echo "/workspace is not a dedicated mount (resolved to ${mount_target})" >&2
  exit 1
}
workspace_size_bytes="$(df -B1 --output=size /workspace | tail -n 1 | tr -d '[:space:]')"
workspace_free_bytes="$(df -B1 --output=avail /workspace | tail -n 1 | tr -d '[:space:]')"
if [[ ! "${workspace_free_bytes}" =~ ^[0-9]+$ ]] || (( workspace_free_bytes < minimum_workspace_bytes )); then
  echo "Insufficient free space on /workspace: ${workspace_free_bytes} bytes" >&2
  exit 1
fi

mkdir -p "$(dirname -- "${state_path}")"
temporary_path="${state_path}.tmp.$$"
printf '{"schema_version":1,"qualified":true,"gpu_name":"%s","gpu_count":1,"gpu_memory_mib":%s,"compute_capability":"%s","cuda_release":"%s","workspace_mount":"/workspace","workspace_size_bytes":%s,"workspace_free_bytes":%s}\n' \
  "${gpu_name}" "${gpu_memory_mib}" "${compute_capability}" "${cuda_release}" \
  "${workspace_size_bytes}" "${workspace_free_bytes}" >"${temporary_path}"
chmod 600 "${temporary_path}"
mv -f "${temporary_path}" "${state_path}"
cat "${state_path}"

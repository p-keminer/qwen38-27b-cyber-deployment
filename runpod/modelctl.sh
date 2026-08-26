#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runpod/lib.sh
source "${script_dir}/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  modelctl.sh list
  modelctl.sh download MODEL_ID
  modelctl.sh download-all
  modelctl.sh verify MODEL_ID
  modelctl.sh path MODEL_ID
  modelctl.sh mmproj MODEL_ID
  modelctl.sh alias MODEL_ID
EOF
}

download_model() {
  local model_id="$1"
  local record repo_id revision filename target_dir target_file metadata_file
  local expected_sha256 expected_size_bytes actual_size_bytes sha256
  local projector_filename projector_file projector_expected_sha256
  local projector_expected_size_bytes projector_actual_size_bytes projector_sha256
  local lock_file model_source artifact_source needs_download

  require_command jq
  require_command flock
  require_command sha256sum
  record="$(model_json "${model_id}")"
  repo_id="$(jq -er '.repo_id' <<<"${record}")"
  revision="$(jq -er '.revision' <<<"${record}")"
  filename="$(jq -er '.filename' <<<"${record}")"
  expected_size_bytes="$(jq -er '.expected_size_bytes' <<<"${record}")"
  expected_sha256="$(jq -er '.sha256' <<<"${record}")"
  projector_filename="$(jq -er '.vision_projector.filename' <<<"${record}")"
  projector_expected_size_bytes="$(jq -er '.vision_projector.expected_size_bytes' <<<"${record}")"
  projector_expected_sha256="$(jq -er '.vision_projector.sha256' <<<"${record}")"
  target_dir="${models_dir}/${model_id}"
  target_file="${target_dir}/${filename}"
  projector_file="${target_dir}/${projector_filename}"
  metadata_file="${target_dir}/download.json"
  lock_file="${state_dir}/download-${model_id}.lock"
  mkdir -p "${target_dir}"

  exec 9>"${lock_file}"
  flock 9

  model_source="${QWEN_MODEL_SOURCE:-prefer-local}"
  case "${model_source}" in
    hub|prefer-local|local-only) ;;
    *) die "Unsupported QWEN_MODEL_SOURCE: ${model_source}" ;;
  esac

  needs_download="true"
  artifact_source="hugging_face_hub"
  if [[ -s "${target_file}" && -s "${projector_file}" ]] &&
     [[ "$(stat -c %s "${target_file}")" == "${expected_size_bytes}" ]] &&
     [[ "$(stat -c %s "${projector_file}")" == "${projector_expected_size_bytes}" ]]; then
    sha256="$(sha256sum "${target_file}" | awk '{print $1}')"
    projector_sha256="$(sha256sum "${projector_file}" | awk '{print $1}')"
    if [[ "${sha256}" == "${expected_sha256}" && "${projector_sha256}" == "${projector_expected_sha256}" ]]; then
      needs_download="false"
      artifact_source="existing_local"
      printf 'Using verified existing artifacts for %s without Hub access.\n' "${model_id}"
    else
      die "Existing model artifacts failed SHA-256 verification for ${model_id}"
    fi
  fi

  if [[ "${needs_download}" == "true" ]]; then
    [[ "${model_source}" != "local-only" ]] || \
      die "Local-only model source is missing complete verified artifacts for ${model_id}"
    require_command hf
    printf 'Preparing %s from %s at %s\n' "${model_id}" "${repo_id}" "${revision}"
    hf download "${repo_id}" \
      --revision "${revision}" \
      --include "${filename}" \
      --local-dir "${target_dir}" \
      --max-workers "${HF_MAX_WORKERS:-4}"
    hf download "${repo_id}" \
      --revision "${revision}" \
      --include "${projector_filename}" \
      --local-dir "${target_dir}" \
      --max-workers "${HF_MAX_WORKERS:-4}"
  fi

  [[ -s "${target_file}" ]] || die "Download did not produce ${target_file}"
  [[ -s "${projector_file}" ]] || die "Download did not produce ${projector_file}"
  actual_size_bytes="$(stat -c %s "${target_file}")"
  projector_actual_size_bytes="$(stat -c %s "${projector_file}")"
  (( actual_size_bytes == expected_size_bytes )) \
    || die "Model size mismatch: ${actual_size_bytes} bytes (expected ${expected_size_bytes})"
  (( projector_actual_size_bytes == projector_expected_size_bytes )) \
    || die "Vision projector size mismatch: ${projector_actual_size_bytes} bytes (expected ${projector_expected_size_bytes})"
  sha256="$(sha256sum "${target_file}" | awk '{print $1}')"
  projector_sha256="$(sha256sum "${projector_file}" | awk '{print $1}')"
  [[ "${sha256}" == "${expected_sha256}" ]] || die "Model SHA-256 mismatch for ${filename}"
  [[ "${projector_sha256}" == "${projector_expected_sha256}" ]] || die "Vision projector SHA-256 mismatch for ${projector_filename}"
  {
    printf '%s  %s\n' "${sha256}" "${filename}"
    printf '%s  %s\n' "${projector_sha256}" "${projector_filename}"
  } >"${target_dir}/model.sha256"
  jq -n \
    --arg id "${model_id}" \
    --arg repo_id "${repo_id}" \
    --arg revision "${revision}" \
    --arg filename "${filename}" \
    --arg sha256 "${sha256}" \
    --argjson size_bytes "${actual_size_bytes}" \
    --arg projector_filename "${projector_filename}" \
    --arg projector_sha256 "${projector_sha256}" \
    --argjson projector_size_bytes "${projector_actual_size_bytes}" \
    --arg source "${artifact_source}" \
    --arg downloaded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{id:$id,repo_id:$repo_id,revision:$revision,source:$source,filename:$filename,size_bytes:$size_bytes,sha256:$sha256,vision_projector:{filename:$projector_filename,size_bytes:$projector_size_bytes,sha256:$projector_sha256},downloaded_at:$downloaded_at}' \
    >"${metadata_file}"
  printf 'Model ready: %s\n' "${target_file}"
}

verify_model() {
  local model_id="$1" record filename projector_filename target_file projector_file
  local expected_size expected_sha projector_expected_size projector_expected_sha
  record="$(model_json "${model_id}")"
  filename="$(jq -er '.filename' <<<"${record}")"
  projector_filename="$(jq -er '.vision_projector.filename' <<<"${record}")"
  expected_size="$(jq -er '.expected_size_bytes' <<<"${record}")"
  expected_sha="$(jq -er '.sha256' <<<"${record}")"
  projector_expected_size="$(jq -er '.vision_projector.expected_size_bytes' <<<"${record}")"
  projector_expected_sha="$(jq -er '.vision_projector.sha256' <<<"${record}")"
  target_file="${models_dir}/${model_id}/${filename}"
  projector_file="${models_dir}/${model_id}/${projector_filename}"
  [[ -s "${target_file}" && "$(stat -c %s "${target_file}")" == "${expected_size}" ]] || \
    die "Model file is missing or has the wrong size: ${target_file}"
  [[ -s "${projector_file}" && "$(stat -c %s "${projector_file}")" == "${projector_expected_size}" ]] || \
    die "Vision projector is missing or has the wrong size: ${projector_file}"
  [[ "$(sha256sum "${target_file}" | awk '{print $1}')" == "${expected_sha}" ]] || \
    die "Model SHA-256 mismatch for ${filename}"
  [[ "$(sha256sum "${projector_file}" | awk '{print $1}')" == "${projector_expected_sha}" ]] || \
    die "Vision projector SHA-256 mismatch for ${projector_filename}"
  printf 'Model and projector SHA-256 verified: %s\n' "${model_id}"
}

command_name="${1:-}"
case "${command_name}" in
  list)
    jq -r '.models[] | [.id, .alias, .repo_id, .revision, .filename] | @tsv' "${manifest_path}"
    ;;
  download)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    download_model "$2"
    ;;
  download-all)
    while IFS= read -r model_id; do
      download_model "${model_id}"
    done < <(jq -r '.models[].id' "${manifest_path}")
    ;;
  verify)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    verify_model "$2"
    ;;
  path)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    record="$(model_json "$2")"
    printf '%s/%s/%s\n' "${models_dir}" "$2" "$(jq -er '.filename' <<<"${record}")"
    ;;
  mmproj)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    record="$(model_json "$2")"
    printf '%s/%s/%s\n' "${models_dir}" "$2" "$(jq -er '.vision_projector.filename' <<<"${record}")"
    ;;
  alias)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    model_json "$2" | jq -er '.alias'
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

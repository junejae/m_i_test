#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
BACKUP_FILE="${ROOT_DIR}/.env.bak.slot2.$(date +%Y%m%d-%H%M%S)"
TARGET_LEN="${1:-${CONTEXT_LEN:-2048}}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

if ! [[ "${TARGET_LEN}" =~ ^[0-9]+$ ]]; then
  echo "CONTEXT_LEN must be a number (e.g. 1024, 1536, 2048)." >&2
  exit 1
fi

if (( TARGET_LEN < 512 )); then
  echo "CONTEXT_LEN must be >= 512." >&2
  exit 1
fi

cp "${ENV_FILE}" "${BACKUP_FILE}"
echo "Backup: ${BACKUP_FILE}"

set_kv() {
  local key="$1"
  local val="$2"
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    if sed --version >/dev/null 2>&1; then
      sed -i -E "s|^${key}=.*$|${key}=${val}|" "${ENV_FILE}"
    else
      sed -i '' -E "s|^${key}=.*$|${key}=${val}|" "${ENV_FILE}"
    fi
  else
    printf "\n%s=%s\n" "${key}" "${val}" >> "${ENV_FILE}"
  fi
}

echo "Applying slot2 OCR/VL context profile: ${TARGET_LEN}"
set_kv "MAX_MODEL_LEN_2" "${TARGET_LEN}"
set_kv "MAX_NUM_SEQS_2" "1"
set_kv "MM_IMAGE_LIMIT_2" "1"
set_kv "MM_VIDEO_LIMIT_2" "0"

if (( TARGET_LEN >= 2048 )); then
  set_kv "MAX_NUM_BATCHED_TOKENS_2" "1024"
  set_kv "GPU_MEMORY_UTILIZATION_2" "0.92"
  set_kv "VLLM_EXTRA_ARGS_2" "--swap-space 24 --cpu-offload-gb 12 --enforce-eager"
elif (( TARGET_LEN >= 1536 )); then
  set_kv "MAX_NUM_BATCHED_TOKENS_2" "768"
  set_kv "GPU_MEMORY_UTILIZATION_2" "0.90"
  set_kv "VLLM_EXTRA_ARGS_2" "--swap-space 24 --cpu-offload-gb 12 --enforce-eager"
elif (( TARGET_LEN >= 1024 )); then
  set_kv "MAX_NUM_BATCHED_TOKENS_2" "512"
  set_kv "GPU_MEMORY_UTILIZATION_2" "0.90"
  set_kv "VLLM_EXTRA_ARGS_2" "--swap-space 24 --cpu-offload-gb 12 --enforce-eager"
else
  set_kv "MAX_NUM_BATCHED_TOKENS_2" "256"
  set_kv "GPU_MEMORY_UTILIZATION_2" "0.90"
  set_kv "VLLM_EXTRA_ARGS_2" "--swap-space 24 --cpu-offload-gb 12 --enforce-eager"
fi

echo "Recreating mig-vllm-2..."
docker compose up -d --force-recreate mig-vllm-2

echo "Done."
echo "Verify health:"
echo "  curl -sS http://127.0.0.1:\${PORT_2:-8102}/health"
echo "Verify OCR/VL:"
echo "  curl -sS http://127.0.0.1:\${PORT_2:-8102}/v1/models"

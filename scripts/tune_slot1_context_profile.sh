#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
BACKUP_FILE="${ROOT_DIR}/.env.bak.slot1.$(date +%Y%m%d-%H%M%S)"
TARGET_LEN="${1:-${CONTEXT_LEN:-4096}}"
BASE_EXTRA_ARGS="--swap-space 8 --enforce-eager --reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser qwen3_coder"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

if ! [[ "${TARGET_LEN}" =~ ^[0-9]+$ ]]; then
  echo "CONTEXT_LEN must be a number (e.g. 4096 or 8192)." >&2
  exit 1
fi

if (( TARGET_LEN < 1024 )); then
  echo "CONTEXT_LEN must be >= 1024." >&2
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

echo "Applying slot1 context profile: ${TARGET_LEN}"
set_kv "MAX_MODEL_LEN_1" "${TARGET_LEN}"
set_kv "MAX_NUM_BATCHED_TOKENS_1" "${TARGET_LEN}"
set_kv "MAX_NUM_SEQS_1" "1"

if (( TARGET_LEN >= 8192 )); then
  set_kv "GPU_MEMORY_UTILIZATION_1" "0.95"
  set_kv "VLLM_EXTRA_ARGS_1" "--swap-space 16 --enforce-eager --reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser qwen3_coder"
elif (( TARGET_LEN >= 4096 )); then
  set_kv "GPU_MEMORY_UTILIZATION_1" "0.92"
  set_kv "VLLM_EXTRA_ARGS_1" "${BASE_EXTRA_ARGS}"
else
  set_kv "GPU_MEMORY_UTILIZATION_1" "0.90"
  set_kv "VLLM_EXTRA_ARGS_1" "${BASE_EXTRA_ARGS}"
fi

echo "Recreating mig-vllm-1..."
docker compose up -d --force-recreate mig-vllm-1

echo "Done."
echo "Verify health:"
echo "  curl -sS http://127.0.0.1:\${PORT_1:-8101}/health"
echo "Verify context:"
echo "  curl -sS http://127.0.0.1:\${PORT_1:-8101}/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"qwen3.5-4b\",\"messages\":[{\"role\":\"user\",\"content\":\"긴 문맥 테스트\"}],\"max_tokens\":64}'"

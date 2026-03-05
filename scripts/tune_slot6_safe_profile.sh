#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
BACKUP_FILE="${ROOT_DIR}/.env.bak.$(date +%Y%m%d-%H%M%S)"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2
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

echo "Applying conservative slot6 profile..."
set_kv "GPU_MEMORY_UTILIZATION_6" "0.70"
set_kv "MAX_MODEL_LEN_6" "256"
set_kv "MAX_NUM_SEQS_6" "1"
set_kv "MAX_NUM_BATCHED_TOKENS_6" "64"
set_kv "VLLM_EXTRA_ARGS_6" "--swap-space 8 --enforce-eager"

echo "Recreating mig-vllm-6..."
docker compose up -d --force-recreate mig-vllm-6

echo "Done. Check logs with:"
echo "  docker compose logs -f --tail=200 mig-vllm-6"
echo ""
echo "Then re-test with:"
echo "  ./scripts/debug_slot6_tts.sh"

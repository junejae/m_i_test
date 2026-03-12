#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo ".env not found at ${ENV_FILE}" >&2
  echo "Create it first, for example: cp .env.example .env" >&2
  exit 1
fi

BACKUP_FILE="${ENV_FILE}.bak.slot1-qwen35.$(date +%Y%m%d-%H%M%S)"
cp "${ENV_FILE}" "${BACKUP_FILE}"
echo "Backup: ${BACKUP_FILE}"

set_kv() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    if sed --version >/dev/null 2>&1; then
      sed -i -E "s|^${key}=.*$|${key}=${value}|" "${ENV_FILE}"
    else
      sed -i '' -E "s|^${key}=.*$|${key}=${value}|" "${ENV_FILE}"
    fi
  else
    printf "\n%s=%s\n" "${key}" "${value}" >> "${ENV_FILE}"
  fi
}

set_kv "MODEL_1" "Qwen/Qwen3.5-4B"
set_kv "SERVED_MODEL_NAME_1" "qwen3.5-4b"
set_kv "VLLM_OPENAI_IMAGE_1" "vllm/vllm-openai:v0.17.0"
set_kv "DTYPE_1" "bfloat16"
set_kv "VLLM_EXTRA_ARGS_1" "--swap-space 8 --enforce-eager --reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser qwen3_coder"

echo "Updated slot1 settings:"
grep -E '^(MODEL_1|SERVED_MODEL_NAME_1|VLLM_OPENAI_IMAGE_1|DTYPE_1|VLLM_EXTRA_ARGS_1)=' "${ENV_FILE}" || true

cat <<'EOF'
Next:
  docker compose pull mig-vllm-1
  docker compose up -d --force-recreate mig-vllm-1
EOF

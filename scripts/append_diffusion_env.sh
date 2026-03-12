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

append_if_missing() {
  local key="$1"
  local value="$2"

  if grep -q "^${key}=" "${ENV_FILE}"; then
    echo "skip ${key} (already exists)"
    return
  fi

  printf "%s=%s\n" "${key}" "${value}" >> "${ENV_FILE}"
  echo "append ${key}"
}

if [[ ! -s "${ENV_FILE}" ]]; then
  : > "${ENV_FILE}"
fi

last_char="$(tail -c 1 "${ENV_FILE}" 2>/dev/null || true)"
if [[ -n "${last_char}" ]]; then
  printf "\n" >> "${ENV_FILE}"
fi

append_if_missing "MIG_UUID_7" "MIG-REPLACE-WITH-UUID-7"
append_if_missing "PORT_7" "8107"
append_if_missing "DIFFUSION_MODEL_7" "runwayml/stable-diffusion-v1-5"
append_if_missing "DIFFUSION_DEVICE_7" "cuda"
append_if_missing "DIFFUSION_DTYPE_7" "float16"
append_if_missing "DIFFUSION_DEFAULT_HEIGHT_7" "512"
append_if_missing "DIFFUSION_DEFAULT_WIDTH_7" "512"
append_if_missing "DIFFUSION_DEFAULT_STEPS_7" "20"
append_if_missing "DIFFUSION_DEFAULT_GUIDANCE_7" "7.5"
append_if_missing "DIFFUSION_NEGATIVE_PROMPT_7" "blurry,low-quality,distorted"
append_if_missing "DIFFUSION_ENABLE_CPU_OFFLOAD_7" "0"

echo
echo "Done. Current diffusion-related keys:"
grep -E '^(MIG_UUID_7|PORT_7|DIFFUSION_[A-Z0-9_]+)=' "${ENV_FILE}" || true

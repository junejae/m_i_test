#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE_FILE="${PROJECT_ROOT}/.env.example"

MIG_TARGET_GPU_INDEX="${MIG_TARGET_GPU_INDEX:-1}"
MIG_CREATE_ARGS="${MIG_CREATE_ARGS:-}"
SKIP_COMPOSE_UP="${SKIP_COMPOSE_UP:-0}"
RUN_MIG_PREPARE="${RUN_MIG_PREPARE:-1}"

if [[ ! -f "${ENV_EXAMPLE_FILE}" ]]; then
  echo ".env.example not found at ${ENV_EXAMPLE_FILE}" >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${ENV_EXAMPLE_FILE}" "${ENV_FILE}"
  echo "Created ${ENV_FILE} from .env.example"
fi

upsert_env() {
  local key="$1"
  local value="$2"
  local tmp_file
  tmp_file="$(mktemp)"

  if grep -q "^${key}=" "${ENV_FILE}"; then
    awk -v k="${key}" -v v="${value}" '
      $0 ~ "^" k "=" { print k "=" v; next }
      { print }
    ' "${ENV_FILE}" > "${tmp_file}"
  else
    cat "${ENV_FILE}" > "${tmp_file}"
    printf "\n%s=%s\n" "${key}" "${value}" >> "${tmp_file}"
  fi

  mv "${tmp_file}" "${ENV_FILE}"
}

echo "[1/4] Preparing MIG on GPU ${MIG_TARGET_GPU_INDEX} only"
if [[ "${RUN_MIG_PREPARE}" == "1" ]]; then
  if [[ -n "${MIG_CREATE_ARGS}" ]]; then
    set +e
    MIG_TARGET_GPU_INDEX="${MIG_TARGET_GPU_INDEX}" \
    MIG_CREATE_ARGS="${MIG_CREATE_ARGS}" \
    "${SCRIPT_DIR}/mig_prepare_gpu1.sh"
    PREPARE_RC=$?
    set -e
  else
    set +e
    MIG_TARGET_GPU_INDEX="${MIG_TARGET_GPU_INDEX}" \
    "${SCRIPT_DIR}/mig_prepare_gpu1.sh"
    PREPARE_RC=$?
    set -e
  fi

  if [[ "${PREPARE_RC}" -ne 0 ]]; then
    cat <<EOF
MIG prepare step failed (exit=${PREPARE_RC}).
This commonly happens when another client holds GPU ${MIG_TARGET_GPU_INDEX}.
Continuing with existing MIG layout and trying UUID extraction.
If MIG is already created, this is safe.
EOF
  fi
else
  echo "RUN_MIG_PREPARE=0, skipping MIG prepare and using existing MIG layout."
fi

echo "[2/4] Reading MIG UUIDs from GPU ${MIG_TARGET_GPU_INDEX}"
UUID_LINES="$(
  MIG_TARGET_GPU_INDEX="${MIG_TARGET_GPU_INDEX}" \
  "${SCRIPT_DIR}/print_mig_uuid_env.sh"
)"

UUID_COUNT="$(printf "%s\n" "${UUID_LINES}" | grep -c '^MIG_UUID_[0-9]\+=MIG-' || true)"
if [[ "${UUID_COUNT}" -lt 4 ]]; then
  echo "Need at least 4 MIG UUIDs on GPU ${MIG_TARGET_GPU_INDEX}, found ${UUID_COUNT}" >&2
  echo "Current output:" >&2
  printf "%s\n" "${UUID_LINES}" >&2
  exit 1
fi

UUID1="$(printf "%s\n" "${UUID_LINES}" | awk -F= '/^MIG_UUID_1=/{print $2; exit}')"
UUID2="$(printf "%s\n" "${UUID_LINES}" | awk -F= '/^MIG_UUID_2=/{print $2; exit}')"
UUID3="$(printf "%s\n" "${UUID_LINES}" | awk -F= '/^MIG_UUID_3=/{print $2; exit}')"
UUID4="$(printf "%s\n" "${UUID_LINES}" | awk -F= '/^MIG_UUID_4=/{print $2; exit}')"

if [[ -z "${UUID1}" || -z "${UUID2}" || -z "${UUID3}" || -z "${UUID4}" ]]; then
  echo "Failed to parse MIG_UUID_1, MIG_UUID_2, MIG_UUID_3, or MIG_UUID_4" >&2
  printf "%s\n" "${UUID_LINES}" >&2
  exit 1
fi

echo "[3/4] Updating .env with MIG_UUID_1..MIG_UUID_4"
upsert_env "MIG_TARGET_GPU_INDEX" "${MIG_TARGET_GPU_INDEX}"
upsert_env "MIG_UUID_1" "${UUID1}"
upsert_env "MIG_UUID_2" "${UUID2}"
upsert_env "MIG_UUID_3" "${UUID3}"
upsert_env "MIG_UUID_4" "${UUID4}"

echo "Updated ${ENV_FILE}:"
grep '^MIG_TARGET_GPU_INDEX=' "${ENV_FILE}" || true
grep '^MIG_UUID_1=' "${ENV_FILE}" || true
grep '^MIG_UUID_2=' "${ENV_FILE}" || true
grep '^MIG_UUID_3=' "${ENV_FILE}" || true
grep '^MIG_UUID_4=' "${ENV_FILE}" || true

if [[ "${SKIP_COMPOSE_UP}" == "1" ]]; then
  echo "[4/4] SKIP_COMPOSE_UP=1, skipping docker compose up"
  exit 0
fi

echo "[4/4] Starting services with docker compose"
cd "${PROJECT_ROOT}"
docker compose up -d
docker compose ps

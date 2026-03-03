#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE_FILE="${PROJECT_ROOT}/.env.example"
MIG_TARGET_GPU_INDEX="${MIG_TARGET_GPU_INDEX:-1}"

if [[ ! -f "${ENV_EXAMPLE_FILE}" ]]; then
  echo ".env.example not found at ${ENV_EXAMPLE_FILE}" >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${ENV_EXAMPLE_FILE}" "${ENV_FILE}"
  echo "Created ${ENV_FILE} from .env.example"
fi

cp "${ENV_FILE}" "${ENV_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

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

ensure_proxy_api_key() {
  local current_key
  current_key="$(awk -F= '$1=="PROXY_API_KEY" {print $2; exit}' "${ENV_FILE}" || true)"

  if [[ -n "${PROXY_API_KEY:-}" ]]; then
    upsert_env "PROXY_API_KEY" "${PROXY_API_KEY}"
    return
  fi

  if [[ -n "${current_key}" && "${current_key}" != "CHANGE-THIS-STRONG-KEY" ]]; then
    return
  fi

  if [[ ! -t 0 ]]; then
    cat <<'EOF' >&2
PROXY_API_KEY is missing/placeholder and no interactive TTY is available.
Set it first, then rerun:
  export PROXY_API_KEY=<your-key>
EOF
    exit 1
  fi

  local key1=""
  local key2=""
  while true; do
    read -r -s -p "Enter PROXY_API_KEY: " key1
    echo
    read -r -s -p "Confirm PROXY_API_KEY: " key2
    echo
    if [[ -z "${key1}" ]]; then
      echo "PROXY_API_KEY cannot be empty."
      continue
    fi
    if [[ "${key1}" != "${key2}" ]]; then
      echo "Values do not match. Try again."
      continue
    fi
    break
  done

  upsert_env "PROXY_API_KEY" "${key1}"
}

echo "[1/3] Reading MIG UUIDs from GPU ${MIG_TARGET_GPU_INDEX}"
UUID_LINES="$(
  MIG_TARGET_GPU_INDEX="${MIG_TARGET_GPU_INDEX}" \
  "${SCRIPT_DIR}/print_mig_uuid_env.sh"
)"

UUID_COUNT="$(printf "%s\n" "${UUID_LINES}" | grep -c '^MIG_UUID_[0-9]\+=MIG-' || true)"
if [[ "${UUID_COUNT}" -lt 6 ]]; then
  echo "Need at least 6 MIG UUIDs on GPU ${MIG_TARGET_GPU_INDEX}, found ${UUID_COUNT}" >&2
  printf "%s\n" "${UUID_LINES}" >&2
  exit 1
fi

for i in 1 2 3 4 5 6; do
  key="MIG_UUID_${i}"
  val="$(printf "%s\n" "${UUID_LINES}" | awk -F= -v k="${key}" '$1==k {print $2; exit}')"
  if [[ -z "${val}" ]]; then
    echo "Failed to parse ${key}" >&2
    exit 1
  fi
  upsert_env "${key}" "${val}"
done
upsert_env "MIG_TARGET_GPU_INDEX" "${MIG_TARGET_GPU_INDEX}"
ensure_proxy_api_key

echo "[2/3] Validating .env MIG keys"
for i in 1 2 3 4 5 6; do
  key="MIG_UUID_${i}"
  value="$(awk -F= -v k="${key}" '$1==k {print $2; exit}' "${ENV_FILE}")"
  if [[ "${value}" == MIG-REPLACE-WITH-* || -z "${value}" ]]; then
    echo "Invalid ${key}=${value}" >&2
    exit 1
  fi
done

echo "[3/3] Updated ${ENV_FILE}"
grep -E '^MIG_TARGET_GPU_INDEX=|^MIG_UUID_[1-6]=' "${ENV_FILE}" || true
if grep -q '^PROXY_API_KEY=' "${ENV_FILE}"; then
  key_len="$(awk -F= '$1=="PROXY_API_KEY" {print length($2); exit}' "${ENV_FILE}")"
  echo "PROXY_API_KEY=*** (length=${key_len})"
fi

cat <<'EOF'
Next:
  docker compose up -d
EOF

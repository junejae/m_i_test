#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE_FILE="${PROJECT_ROOT}/.env.example"

TARGET_IP="${TARGET_IP:-}"
FORCE_RECREATE="${FORCE_RECREATE:-1}"

if [[ ! -f "${ENV_EXAMPLE_FILE}" ]]; then
  echo ".env.example not found: ${ENV_EXAMPLE_FILE}" >&2
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

if [[ -z "${TARGET_IP}" ]]; then
  TARGET_IP="$(ip route get 8.8.8.8 | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
fi

if [[ -z "${TARGET_IP}" ]]; then
  echo "Could not detect OS service IP. Set TARGET_IP manually." >&2
  echo "Example: TARGET_IP=172.0.20.94 ./scripts/fix_proxy_server_name.sh" >&2
  exit 1
fi

API_KEY="$(awk -F= '$1=="PROXY_API_KEY" {print $2; exit}' "${ENV_FILE}" || true)"
if [[ -z "${API_KEY}" || "${API_KEY}" == "CHANGE-THIS-STRONG-KEY" ]]; then
  echo "PROXY_API_KEY is missing/placeholder in .env. Set it first." >&2
  exit 1
fi

echo "[1/4] Set PROXY_SERVER_NAME=${TARGET_IP}"
upsert_env "PROXY_SERVER_NAME" "${TARGET_IP}"

echo "[2/4] Recreate proxy-gateway"
cd "${PROJECT_ROOT}"
if [[ "${FORCE_RECREATE}" == "1" ]]; then
  docker compose up -d --force-recreate proxy-gateway
else
  docker compose up -d proxy-gateway
fi

echo "[3/4] Show proxy logs"
docker compose logs --tail=80 proxy-gateway || true

echo "[4/4] Health checks"
echo "- localhost:"
curl -k -sS "https://localhost:443/slot1/health" -H "X-API-Key: ${API_KEY}" || true
echo
echo "- ${TARGET_IP}:"
curl -k -sS "https://${TARGET_IP}:443/slot1/health" -H "X-API-Key: ${API_KEY}" || true
echo

echo "Done."
echo "Current .env:"
grep -E '^PROXY_SERVER_NAME=|^PROXY_API_KEY=' "${ENV_FILE}" | sed 's/^PROXY_API_KEY=.*/PROXY_API_KEY=*** (set)/'


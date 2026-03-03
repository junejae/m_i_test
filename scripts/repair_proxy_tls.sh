#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

RESET_CADDY_VOLUMES="${RESET_CADDY_VOLUMES:-1}"
TLS_TEST_ONLY="${TLS_TEST_ONLY:-0}"
API_KEY_OVERRIDE="${API_KEY_OVERRIDE:-}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo ".env not found at ${ENV_FILE}" >&2
  exit 1
fi

SERVER_NAME="$(awk -F= '$1=="PROXY_SERVER_NAME"{print $2; exit}' "${ENV_FILE}" || true)"
API_KEY="$(awk -F= '$1=="PROXY_API_KEY"{print $2; exit}' "${ENV_FILE}" || true)"
if [[ -n "${API_KEY_OVERRIDE}" ]]; then
  API_KEY="${API_KEY_OVERRIDE}"
fi

if [[ -z "${SERVER_NAME}" ]]; then
  echo "PROXY_SERVER_NAME is missing in .env" >&2
  exit 1
fi
if [[ -z "${API_KEY}" || "${API_KEY}" == "CHANGE-THIS-STRONG-KEY" ]]; then
  echo "PROXY_API_KEY is missing/placeholder in .env" >&2
  exit 1
fi

cd "${PROJECT_ROOT}"

echo "[1/4] TLS handshake test with SNI=${SERVER_NAME}"
set +e
openssl s_client -connect 127.0.0.1:443 -servername "${SERVER_NAME}" -tls1_2 </dev/null >/tmp/proxy_tls_test.out 2>&1
TLS_RC=$?
set -e
if grep -q "BEGIN CERTIFICATE" /tmp/proxy_tls_test.out; then
  echo "TLS handshake looks OK (certificate presented)."
else
  echo "TLS handshake failed or no certificate presented."
  sed -n '1,40p' /tmp/proxy_tls_test.out || true
fi

if [[ "${TLS_TEST_ONLY}" == "1" ]]; then
  exit "${TLS_RC}"
fi

if [[ "${RESET_CADDY_VOLUMES}" == "1" ]]; then
  echo "[2/4] Reset caddy volumes and recreate proxy-gateway"
  docker compose stop proxy-gateway || true
  docker volume rm -f mig-inference_proxy_caddy_data mig-inference_proxy_caddy_config || true
  docker compose up -d proxy-gateway
else
  echo "[2/4] Recreate proxy-gateway without volume reset"
  docker compose up -d --force-recreate proxy-gateway
fi

echo "[3/4] Show recent proxy logs"
docker compose logs --tail=120 proxy-gateway || true

echo "[4/4] Verify TLS and health via SNI-resolved local endpoint"
openssl s_client -connect 127.0.0.1:443 -servername "${SERVER_NAME}" -tls1_2 </dev/null | sed -n '1,25p' || true
curl -k -sS --resolve "${SERVER_NAME}:443:127.0.0.1" \
  "https://${SERVER_NAME}/slot1/health" \
  -H "X-API-Key: ${API_KEY}" || true
echo
echo "Done."


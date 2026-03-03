#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
CERT_DIR="${PROJECT_ROOT}/proxy-nginx/certs"
CRT_FILE="${CERT_DIR}/server.crt"
KEY_FILE="${CERT_DIR}/server.key"

FORCE_RENEW="${FORCE_RENEW:-0}"

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required." >&2
  exit 1
fi

mkdir -p "${CERT_DIR}"

SERVER_NAME="127.0.0.1"
if [[ -f "${ENV_FILE}" ]]; then
  env_name="$(awk -F= '$1=="PROXY_SERVER_NAME"{print $2; exit}' "${ENV_FILE}" || true)"
  if [[ -n "${env_name}" ]]; then
    SERVER_NAME="${env_name}"
  fi
fi

if [[ "${FORCE_RENEW}" == "0" && -s "${CRT_FILE}" && -s "${KEY_FILE}" ]]; then
  echo "TLS cert already exists at ${CRT_FILE}"
  exit 0
fi

SAN="DNS:localhost,IP:127.0.0.1"
if [[ "${SERVER_NAME}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  SAN="${SAN},IP:${SERVER_NAME}"
else
  SAN="${SAN},DNS:${SERVER_NAME}"
fi

openssl req -x509 -nodes -newkey rsa:2048 \
  -days 3650 \
  -keyout "${KEY_FILE}" \
  -out "${CRT_FILE}" \
  -subj "/CN=${SERVER_NAME}" \
  -addext "subjectAltName=${SAN}" >/dev/null 2>&1

chmod 600 "${KEY_FILE}"
chmod 644 "${CRT_FILE}"

echo "Generated:"
echo "  ${CRT_FILE}"
echo "  ${KEY_FILE}"
echo "CN=${SERVER_NAME}"
echo "SAN=${SAN}"


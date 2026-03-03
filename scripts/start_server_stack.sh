#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE_FILE="${PROJECT_ROOT}/.env.example"

MIG_TARGET_GPU_INDEX="${MIG_TARGET_GPU_INDEX:-1}"
AUTO_REPARTITION="${AUTO_REPARTITION:-0}"
MIG_ONE_G_PROFILE_ID="${MIG_ONE_G_PROFILE_ID:-19}"
FORCE_RECREATE="${FORCE_RECREATE:-0}"

if [[ ! -f "${ENV_EXAMPLE_FILE}" ]]; then
  echo ".env.example not found: ${ENV_EXAMPLE_FILE}" >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${ENV_EXAMPLE_FILE}" "${ENV_FILE}"
  echo "Created ${ENV_FILE} from .env.example"
fi

echo "[1/5] Optional MIG repartition"
if [[ "${AUTO_REPARTITION}" == "1" ]]; then
  MIG_TARGET_GPU_INDEX="${MIG_TARGET_GPU_INDEX}" \
  MIG_ONE_G_PROFILE_ID="${MIG_ONE_G_PROFILE_ID}" \
  "${SCRIPT_DIR}/mig_repartition_gpu1_to_7x1g.sh"
else
  echo "AUTO_REPARTITION=0, skipping MIG repartition."
fi

echo "[2/5] Recover .env MIG UUID + PROXY_API_KEY"
MIG_TARGET_GPU_INDEX="${MIG_TARGET_GPU_INDEX}" \
  "${SCRIPT_DIR}/recover_env_mig_uuid.sh"

echo "[3/5] Validate PROXY_SERVER_NAME in .env"
current_server_name="$(awk -F= '$1=="PROXY_SERVER_NAME" {print $2; exit}' "${ENV_FILE}" || true)"
if [[ -z "${current_server_name}" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Enter PROXY_SERVER_NAME (IP or DNS): " current_server_name
    if [[ -z "${current_server_name}" ]]; then
      echo "PROXY_SERVER_NAME cannot be empty." >&2
      exit 1
    fi
    awk -v v="${current_server_name}" -F= '
      BEGIN { found=0 }
      $1=="PROXY_SERVER_NAME" { print "PROXY_SERVER_NAME=" v; found=1; next }
      { print }
      END { if (!found) print "PROXY_SERVER_NAME=" v }
    ' "${ENV_FILE}" > "${ENV_FILE}.tmp"
    mv "${ENV_FILE}.tmp" "${ENV_FILE}"
  else
    echo "PROXY_SERVER_NAME is missing in .env (non-interactive)." >&2
    echo "Set it first, or run interactively." >&2
    exit 1
  fi
fi

echo "[4/6] Ensure proxy TLS cert files"
"${SCRIPT_DIR}/init_proxy_tls_cert.sh"

echo "[5/6] Start docker compose services"
cd "${PROJECT_ROOT}"
if [[ "${FORCE_RECREATE}" == "1" ]]; then
  docker compose up -d --force-recreate
else
  docker compose up -d
fi

echo "[6/6] Summary"
docker compose ps
echo
echo "Quick checks:"
echo "  curl -k -sS https://127.0.0.1:443/slot1/health -H \"X-API-Key: <PROXY_API_KEY>\""
echo "  curl -k -sS https://127.0.0.1:443/slot1/v1/models -H \"X-API-Key: <PROXY_API_KEY>\""

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_BASE_URL="${REMOTE_DIFFUSION_BASE_URL:-https://pty-metadata-ltd-loving.trycloudflare.com}"
DEFAULT_API_KEY="${REMOTE_DIFFUSION_API_KEY:-}"
SERVER_PORT="${REMOTE_DIFFUSION_GRADIO_PORT:-7868}"
TIMEOUT_SECONDS="${REMOTE_DIFFUSION_TIMEOUT:-300}"

if [[ -z "${DEFAULT_API_KEY}" && -f "${ROOT_DIR}/.env" ]]; then
  DEFAULT_API_KEY="$(awk -F= '$1=="PROXY_API_KEY" {print $2; exit}' "${ROOT_DIR}/.env" || true)"
fi

cd "${ROOT_DIR}"
uv run --with gradio --with requests --with pillow \
  python3 scripts/remote_diffusion_gradio.py \
  --base-url "${DEFAULT_BASE_URL}" \
  --api-key "${DEFAULT_API_KEY}" \
  --server-port "${SERVER_PORT}" \
  --timeout "${TIMEOUT_SECONDS}"

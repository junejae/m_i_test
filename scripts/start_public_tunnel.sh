#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[1/3] Starting proxy gateway (if not running)"
docker compose up -d proxy-gateway

echo "[2/3] Starting Cloudflare quick tunnel"
docker compose --profile tunnel up -d edge-tunnel

echo "[3/3] Waiting for public URL"
URL=""
for _ in $(seq 1 30); do
  URL="$(docker compose logs --no-color edge-tunnel 2>/dev/null | grep -Eo 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' | tail -n 1 || true)"
  if [[ -n "$URL" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$URL" ]]; then
  echo "Failed to detect tunnel URL. Check logs:"
  echo "  docker compose logs --tail=200 edge-tunnel"
  exit 1
fi

echo ""
echo "Public tunnel URL:"
echo "  $URL"
echo ""
echo "Health check example:"
echo "  curl -sS \"$URL/slot1/health\" -H \"X-API-Key: \${PROXY_API_KEY}\""
